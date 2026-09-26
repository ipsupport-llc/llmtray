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

# FLUX.2 klein (generation and editing): the prompt and any reference
# images (base64 PNG / JPEG) arrive as one JSON object on stdin, the images
# decoded in memory -- no file is written, not even for editing.
if arg("--base-model") == "flux2-klein-4b":
    import json
    from PIL import Image
    from mflux.models.common.vae.tiling_config import TilingConfig
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
    steps = int(arg("--steps", "4"))

    class Steps:
        def call_before_loop(self, *_, **__):
            emit("STEP", f"0 {steps}")

        def call_in_loop(self, t, *_, **__):
            emit("STEP", f"{t + 1} {steps}")

    model.callbacks.register(Steps())
    kwargs = dict(seed=int(arg("--seed", "0")) or int.from_bytes(os.urandom(4), "big"), prompt=request["prompt"],
                  num_inference_steps=steps, width=int(arg("--width", "1024")), height=int(arg("--height", "1024")))
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
        unpacked = ZImageLatentCreator.unpack_latents(latents=latents, height=config.height, width=config.width)
        channels = getattr(model.vae, "latent_channels", 32)
        if hasattr(model.vae, "decode_packed_latents") and unpacked.shape[1] > channels:
            decoded = model.vae.decode_packed_latents(unpacked)
        else:
            decoded = model.vae.decode(unpacked)
        image = ImageUtil.to_image(
            decoded_latents=decoded, config=config, seed=seed, prompt=prompt,
            quantization=model.bits, lora_paths=None, lora_scales=None, generation_time=0,
        )
        emit("PREVIEW", png_b64(image.image, max_side=512))

model.callbacks.register(Preview())
width, height = args.width, args.height
image = model.generate_image(
    seed=args.seed[0], prompt=args.prompt, width=width, height=height,
    guidance=args.guidance, num_inference_steps=args.steps, scheduler=args.scheduler,
)
emit("IMAGE", png_b64(image.image))
