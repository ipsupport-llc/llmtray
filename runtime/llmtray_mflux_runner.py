# LLMTray's in-memory mflux runner: nothing is written to disk. Progress,
# step previews and the final PNG go to stdout as "@@LLMTRAY <KIND> <data>"
# lines (PNG as base64); everything else mflux prints goes to stderr.
import base64, io, os, sys
# The protocol gets its own copy of fd 1; fd 1 itself (and Python's stdout)
# then point at stderr, so nothing printed by mflux or native code can land
# in the middle of a protocol line.
protocol = os.fdopen(os.dup(1), "wb")
os.dup2(2, 1)
sys.stdout = sys.stderr

def emit(kind, data=""):
    protocol.write(f"@@LLMTRAY {kind} {data}\n".encode())
    protocol.flush()

def png_b64(pil, max_side=None):
    if max_side and max(pil.size) > max_side:
        pil = pil.copy()
        pil.thumbnail((max_side, max_side))
    buf = io.BytesIO()
    pil.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()

def arg(name, default=None):
    """--name value from argv (the FLUX.2 path takes a few plain flags)."""
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default

# MLX keeps freed buffers for reuse, by default up to its memory limit:
# a 1024 px Z-Image held 19.7 GB that way and 12.8 GB with this cache, and
# ran no slower (155 s vs 204 s on a 24 GB Mac -- scripts/measure_memory.py,
# 2026-10-01); FLUX.2 klein editing 17.8 GB vs about half.
import mlx.core as mx
mx.set_cache_limit(256 << 20)

import gc
from mlx.utils import tree_flatten, tree_map
def drop(model, name):
    """One image per run: a model goes once it's done -- its weights, not
    just the attribute (mflux's loops may still hold the module)."""
    module = getattr(model, name)
    module.update(tree_map(lambda x: mx.zeros((0,), x.dtype), module.parameters()))
    setattr(model, name, None)
    gc.collect()
    mx.clear_cache()

def half_size(packed):
    """(B, C, H, W) latents at half the size, for a preview: a full-size
    decode at every step costs gigabytes for a 512 px picture."""
    b, c, h, w = packed.shape
    if h % 2 or w % 2:
        return packed
    return packed.reshape(b, c, h // 2, 2, w // 2, 2).mean(axis=(3, 5))

# FLUX.2 klein (generation and editing): the prompt and any reference
# images (base64 PNG / JPEG) arrive as one JSON object on stdin, the images
# decoded in memory -- no file is written, not even for editing.
if arg("--base-model") == "flux2-klein-4b":
    import json
    from PIL import Image
    from mflux.models.common.vae.tiling_config import TilingConfig
    from mflux.utils.image_util import ImageUtil
    request = json.loads(sys.stdin.read())
    def rgb(data):
        im = Image.open(io.BytesIO(base64.b64decode(data)))
        if im.mode in ("RGBA", "LA", "P"):
            # On white: transparent pixels would turn black in "RGB".
            im = im.convert("RGBA")
            im = Image.alpha_composite(Image.new("RGBA", im.size, "white"), im)
        return im.convert("RGB")
    images = [rgb(b) for b in request.get("images", [])]
    # A side under 64 px rounds to nothing in mflux's resize: scaled up.
    # The long side stays within 2048 (beyond 32:1 the image is squeezed).
    images = [im.resize((min(2048, max(64, round(im.width * 64 / min(im.size)))),
                         min(2048, max(64, round(im.height * 64 / min(im.size))))))
              if min(im.size) < 64 else im for im in images]
    if images:
        from mflux.models.flux2.variants.edit.flux2_klein_edit import Flux2KleinEdit as Model
    else:
        from mflux.models.flux2.variants.txt2img.flux2_klein import Flux2Klein as Model
    model = Model(model_path=arg("--model"))
    # Only the text encoder's hidden states 9, 18 and 27 condition the image:
    # layers 27+ never matter (bit-identical output, ~1GB less resident),
    # and the VAE decodes in 256 px tiles (its untiled peak doubles memory).
    model.text_encoder.layers = model.text_encoder.layers[:27]
    model.tiling_config = TilingConfig(vae_decode_tile_size=256)
    # The text encoder (3.1 GB) only encodes the prompt: it goes after, and
    # the denoising and the decodes have its room (an edit peaked at 8.8 GB
    # of MLX memory with it).
    encode_prompt_pair = model._encode_prompt_pair
    def encode_once(*args, **kwargs):
        encodings = encode_prompt_pair(*args, **kwargs)
        mx.eval([v for _, v in tree_flatten(encodings) if isinstance(v, mx.array)])
        drop(model, "text_encoder")
        return encodings
    model._encode_prompt_pair = encode_once
    steps = int(arg("--steps", "4"))
    width, height = int(arg("--width", "1024")), int(arg("--height", "1024"))

    # The preview shows each step's predicted clean image, x0 = x_t - sigma_t * v
    # (flow matching): with 4 steps the latents themselves are noise until
    # the end. mflux 0.20's FLUX.2 loop doesn't hand it to callbacks, so the
    # scheduler step keeps it.
    from mflux.models.common.schedulers.flow_match_euler_discrete_scheduler import FlowMatchEulerDiscreteScheduler
    predicted = {}
    scheduler_step = FlowMatchEulerDiscreteScheduler.step
    def step(self, noise, timestep, latents, **kwargs):
        if timestep + 1 < steps:   # not kept for the last step: no preview there
            # Back to the latents' dtype: the float32 sigma promotes it, and a
            # float32 VAE decode peaks ~0.6GB above the final one (measured).
            predicted["x0"] = (latents - kwargs.get("sigmas", self._sigmas)[timestep] * noise).astype(latents.dtype)
        return scheduler_step(self, noise, timestep, latents, **kwargs)
    FlowMatchEulerDiscreteScheduler.step = step

    class Steps:
        def call_before_loop(self, *_, **__):
            emit("STEP", f"0 {steps}")

        def call_in_loop(self, t, config=None, **_):
            emit("STEP", f"{t + 1} {steps}")
            # A preview of each step but the last (the image itself follows).
            latents = predicted.pop("x0", None)
            if latents is None or t + 1 >= steps:
                return
            try:   # a preview is cosmetic: never the reason a generation fails
                packed = latents.reshape(latents.shape[0], config.height // 16, config.width // 16, latents.shape[-1]).transpose(0, 3, 1, 2)
                decoded = model.vae.decode_packed_latents(half_size(packed), tiling_config=model.tiling_config)
                emit("PREVIEW", png_b64(ImageUtil.to_image(
                    decoded_latents=decoded, config=config, seed=0, prompt="", quantization=model.bits,
                    lora_paths=None, lora_scales=None, generation_time=0,
                ).image, max_side=512))
            except Exception:
                pass

    model.callbacks.register(Steps())
    kwargs = dict(seed=int(arg("--seed", "0")) or int.from_bytes(os.urandom(4), "big"), prompt=request["prompt"],
                  num_inference_steps=steps, width=width, height=height)
    if images:
        kwargs["image_paths"] = images   # mflux's loader takes PIL images as well as paths
    emit("IMAGE", png_b64(model.generate_image(**kwargs).image))
    sys.exit(0)

from mflux.cli.parser.parsers import lora_init_kwargs_from_args
from mflux.models.common.resolution.config_resolution import ConfigResolution
from mflux.models.z_image.cli.z_image_turbo_generate import build_parser
from mflux.models.z_image.latent_creator import ZImageLatentCreator
from mflux.models.z_image.variants.z_image import ZImage
from mflux.utils.image_util import ImageUtil

# The prompt arrives on stdin (kept out of the argument list, which `ps`
# shows); mflux's own parser still validates it.
sys.argv.append("--prompt=" + sys.stdin.read())
args = build_parser().parse_args()  # reads sys.argv
model = ZImage(
    model_config=ConfigResolution.resolve_restricted(args.model, "z-image-turbo", model_path=args.model_path),
    quantize=args.quantize,
    model_path=args.model_path,
    **lora_init_kwargs_from_args(args),
)

class Preview:
    """mflux's StepwiseHandler, minus the files."""
    def call_before_loop(self, seed, prompt, latents, config, **_):
        self.send(0, seed, prompt, latents, config)

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        self.send(t + 1, seed, prompt, latents, config)

    def send(self, step, seed, prompt, latents, config):
        emit("STEP", f"{step} {config.num_inference_steps}")
        # mflux calls this before evaluating the step: the step first, so
        # its activations are gone before the decode's.
        mx.eval(latents)
        # A preview is cosmetic: never the reason a generation fails.
        try:
            unpacked = ZImageLatentCreator.unpack_latents(latents=latents, height=config.height, width=config.width)
            channels = getattr(model.vae, "latent_channels", 32)
            if hasattr(model.vae, "decode_packed_latents") and unpacked.shape[1] > channels:
                decoded = model.vae.decode_packed_latents(unpacked)
            else:
                # Z-Image: a full-size decode at every step cost 1.4 GB more
                # peak and ~28 s at 1024 px.
                decoded = model.vae.decode(half_size(unpacked))
            image = ImageUtil.to_image(
                decoded_latents=decoded, config=config, seed=seed, prompt=prompt,
                quantization=model.bits, lora_paths=None, lora_scales=None, generation_time=0,
            )
            emit("PREVIEW", png_b64(image.image, max_side=512))
        except Exception:
            pass

# One image per run: each model goes once it's done -- the text encoder
# (2 GB) after the prompt, the transformer (4 GB) before the VAE decode,
# whose 1024 px activations (6.6 GB) are the run's peak. 10.8 GB of MLX
# memory at that peak otherwise (measured).

# mflux compiles the denoising step (M3 and later), and the compiled graph
# keeps the transformer's weights as constants: the step goes with them.
compiled = {}
make_predict = ZImage._predict
def predict_handle(transformer):
    compiled["predict"] = make_predict(transformer)
    return lambda *args, **kwargs: compiled["predict"](*args, **kwargs)
ZImage._predict = staticmethod(predict_handle)

encode_prompts = model._encode_prompts
def encode_once(**kwargs):
    encodings = encode_prompts(**kwargs)
    mx.eval([e for e in encodings if e is not None])
    drop(model, "text_encoder")
    return encodings
model._encode_prompts = encode_once

decode_latents = model._decode_latents
def decode_once(**kwargs):
    mx.eval(kwargs["latents"])
    compiled.clear()
    drop(model, "transformer")
    return decode_latents(**kwargs)
model._decode_latents = decode_once

model.callbacks.register(Preview())
width, height = args.width, args.height
image = model.generate_image(
    seed=args.seed[0], prompt=args.prompt, width=width, height=height,
    guidance=args.guidance, num_inference_steps=args.steps, scheduler=args.scheduler,
)
emit("IMAGE", png_b64(image.image))
