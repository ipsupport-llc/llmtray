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
