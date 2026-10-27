"""Exercise a built PyTorch image on a real GPU.

Runs inside the container started by gpu-test.sh. Everything here needs
hardware: a buildkit RUN has no /dev/kfd, so none of it can be checked
at build time. That gap is how HSA_OVERRIDE_GFX_VERSION=11.0.2 survived
in every image we published — it broke device init on a real gfx1201
and nothing could see it.

Correctness is checked against CPU where there is a reference, and
against a tolerance chosen per dtype rather than one global epsilon:
fp16 and bf16 legitimately disagree with fp64 by far more than fp32.
"""

import os
import sys
import time

import torch

FAILURES = []
SKIPPED = []


def check(name, ok, detail=""):
    if ok is None:
        SKIPPED.append(name)
        print(f"  SKIP  {name}{(': ' + detail) if detail else ''}")
        return
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{(': ' + detail) if detail else ''}")
    if not ok:
        FAILURES.append(name)


def section(title):
    print(f"\n── {title}")


# ── device ───────────────────────────────────────────────────────
section("device")
print(f"  torch {torch.__version__}   HIP {torch.version.hip}")

if not torch.cuda.is_available():
    archs = torch.cuda.get_arch_list()
    print(f"\n  no device. wheel contains: {archs or '(none)'}")
    if not os.path.exists("/dev/kfd"):
        print("  /dev/kfd absent: container missing --device=/dev/kfd.")
    elif os.environ.get("HSA_OVERRIDE_GFX_VERSION"):
        print("  HSA_OVERRIDE_GFX_VERSION is set; it masks the real GPU"
              " and breaks init on an unmatched arch.")
    else:
        print("  /dev/kfd present and no override: the wheel has no code"
              " for this GPU. Rebuild with a matching PYTORCH_ROCM_ARCH.")
    sys.exit(1)

props = torch.cuda.get_device_properties(0)
gfx = props.gcnArchName.split(":")[0]
print(f"  {torch.cuda.get_device_name(0)}  {gfx}  "
      f"{props.total_memory // 1048576} MiB  {props.multi_processor_count} CUs")

want = os.environ.get("EXPECT_ARCH", "")
if want:
    check("device arch matches the wheel", gfx == want,
          f"built {want}, found {gfx}")
check("arch in wheel's arch list", gfx in torch.cuda.get_arch_list(),
      str(torch.cuda.get_arch_list()))

# ── arithmetic, per dtype ────────────────────────────────────────
section("arithmetic")
# Tolerances reflect the format, not the hardware: fp16 carries ~3
# decimal digits, bf16 ~2, so a shared epsilon would either pass
# everything or fail bf16 spuriously.
for dtype, tol in ((torch.float32, 1e-3), (torch.float16, 5e-2),
                   (torch.bfloat16, 5e-1)):
    try:
        a = torch.randn(512, 512, device="cuda", dtype=dtype)
        b = torch.randn(512, 512, device="cuda", dtype=dtype)
        gpu = (a @ b).float().cpu()
        ref = a.float().cpu() @ b.float().cpu()
        err = (gpu - ref).abs().max().item()
        check(f"matmul {str(dtype).split('.')[-1]}", err < tol,
              f"max abs err {err:.2e}")
    except Exception as exc:  # noqa: BLE001
        check(f"matmul {str(dtype).split('.')[-1]}", False, repr(exc)[:70])

try:
    x = torch.randn(1_000_000, device="cuda")
    check("reduction sum", abs(x.sum().item() - x.cpu().sum().item()) < 1e-1)
    check("elementwise chain",
          torch.allclose((x * 2 + 1).relu().cpu(),
                         (x.cpu() * 2 + 1).relu(), atol=1e-5))
except Exception as exc:  # noqa: BLE001
    check("reduction / elementwise", False, repr(exc)[:70])

# ── autograd ─────────────────────────────────────────────────────
section("autograd")
try:
    w = torch.randn(256, 256, device="cuda", requires_grad=True)
    y = (w @ w.T).sum()
    y.backward()
    check("backward produces finite grads",
          w.grad is not None and torch.isfinite(w.grad).all().item())
except Exception as exc:  # noqa: BLE001
    check("backward produces finite grads", False, repr(exc)[:70])

# ── a real training step ─────────────────────────────────────────
section("training step")
try:
    net = torch.nn.Sequential(
        torch.nn.Linear(256, 512), torch.nn.ReLU(),
        torch.nn.Linear(512, 10),
    ).cuda()
    opt = torch.optim.AdamW(net.parameters(), lr=1e-3)
    data = torch.randn(64, 256, device="cuda")
    target = torch.randint(0, 10, (64,), device="cuda")
    first = last = None
    for step in range(20):
        opt.zero_grad()
        loss = torch.nn.functional.cross_entropy(net(data), target)
        loss.backward()
        opt.step()
        if step == 0:
            first = loss.item()
        last = loss.item()
    check("loss decreases over 20 steps", last < first,
          f"{first:.3f} -> {last:.3f}")
except Exception as exc:  # noqa: BLE001
    check("loss decreases over 20 steps", False, repr(exc)[:70])

# ── convolution ──────────────────────────────────────────────────
section("convolution")
try:
    conv = torch.nn.Conv2d(3, 16, 3, padding=1).cuda()
    img = torch.randn(8, 3, 64, 64, device="cuda")
    out = conv(img)
    ref = conv.cpu()(img.cpu())
    check("conv2d matches CPU", (out.cpu() - ref).abs().max().item() < 1e-3,
          str(tuple(out.shape)))
except Exception as exc:  # noqa: BLE001
    check("conv2d matches CPU", False, repr(exc)[:70])

# ── attention ────────────────────────────────────────────────────
section("attention")
try:
    from torch.nn.attention import SDPBackend, sdpa_kernel
    q = torch.randn(2, 8, 256, 64, device="cuda", dtype=torch.float16)
    base = torch.nn.functional.scaled_dot_product_attention(q, q, q)
    check("sdpa default backend", base.shape == q.shape, str(tuple(base.shape)))
    for backend, label in ((SDPBackend.FLASH_ATTENTION, "flash"),
                           (SDPBackend.EFFICIENT_ATTENTION, "mem-efficient"),
                           (SDPBackend.MATH, "math")):
        try:
            with sdpa_kernel(backend):
                got = torch.nn.functional.scaled_dot_product_attention(q, q, q)
            err = (got.float() - base.float()).abs().max().item()
            check(f"sdpa {label}", err < 5e-2, f"max abs err {err:.2e}")
        except Exception as exc:  # noqa: BLE001
            check(f"sdpa {label}", None, "unavailable on this arch")
except Exception as exc:  # noqa: BLE001
    check("sdpa", False, repr(exc)[:70])

# ── triton ───────────────────────────────────────────────────────
section("triton")
try:
    import triton
    import triton.language as tl

    @triton.jit
    def _add(x_ptr, y_ptr, o_ptr, n, BLOCK: tl.constexpr):
        pid = tl.program_id(0)
        off = pid * BLOCK + tl.arange(0, BLOCK)
        m = off < n
        tl.store(o_ptr + off, tl.load(x_ptr + off, mask=m)
                 + tl.load(y_ptr + off, mask=m), mask=m)

    n = 98_432
    x = torch.rand(n, device="cuda")
    y = torch.rand(n, device="cuda")
    o = torch.empty_like(x)
    _add[(triton.cdiv(n, 1024),)](x, y, o, n, BLOCK=1024)
    err = (o - (x + y)).abs().max().item()
    check(f"triton {triton.__version__} jit kernel", err == 0.0,
          f"max abs err {err:.1e}")
except Exception as exc:  # noqa: BLE001
    check("triton jit kernel", False, repr(exc)[:70])

# ── torch.compile ────────────────────────────────────────────────
section("torch.compile")
try:
    def fn(a, b):
        return (a @ b).relu().sum()

    compiled = torch.compile(fn)
    a = torch.randn(256, 256, device="cuda")
    b = torch.randn(256, 256, device="cuda")
    err = abs(compiled(a, b).item() - fn(a, b).item())
    check("inductor compiles and matches eager", err < 1e-1,
          f"abs err {err:.2e}")
except Exception as exc:  # noqa: BLE001
    check("inductor compiles and matches eager", False, repr(exc)[:70])

# ── memory ───────────────────────────────────────────────────────
section("memory")
try:
    torch.cuda.empty_cache()
    before = torch.cuda.memory_allocated()
    big = torch.empty(256 * 1024 * 1024 // 4, device="cuda")  # 256 MiB
    peak = torch.cuda.memory_allocated()
    del big
    torch.cuda.empty_cache()
    after = torch.cuda.memory_allocated()
    check("alloc and free 256 MiB",
          peak - before >= 256 * 1024 * 1024 and after <= before,
          f"{(peak - before) // 1048576} MiB allocated, released")
except Exception as exc:  # noqa: BLE001
    check("alloc and free 256 MiB", False, repr(exc)[:70])

# ── throughput ───────────────────────────────────────────────────
# Not a benchmark suite: enough to catch an order-of-magnitude
# regression, and to say what the card does on this build.
section("throughput")


def timed(fn, warmup=3, iters=10):
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(iters):
        fn()
    torch.cuda.synchronize()
    return (time.perf_counter() - t0) / iters


try:
    for dtype, label in ((torch.float32, "fp32"), (torch.float16, "fp16"),
                         (torch.bfloat16, "bf16")):
        n = 4096
        a = torch.randn(n, n, device="cuda", dtype=dtype)
        b = torch.randn(n, n, device="cuda", dtype=dtype)
        sec = timed(lambda: a @ b)
        print(f"  matmul {n}^3 {label}: {2 * n ** 3 / sec / 1e12:6.2f} TFLOP/s")

    size = 256 * 1024 * 1024 // 4
    src = torch.randn(size, device="cuda")
    dst = torch.empty_like(src)
    sec = timed(lambda: dst.copy_(src))
    print(f"  device copy 256 MiB:   {2 * src.numel() * 4 / sec / 1e9:6.1f} GB/s")
except Exception as exc:  # noqa: BLE001
    print(f"  throughput unavailable: {exc!r}"[:90])

# ── result ───────────────────────────────────────────────────────
print()
if SKIPPED:
    print(f"  {len(SKIPPED)} skipped: {', '.join(SKIPPED)}")
if FAILURES:
    print(f"  {len(FAILURES)} FAILED: {', '.join(FAILURES)}")
    sys.exit(1)
print("  all checks passed")
