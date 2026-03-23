import atexit
import os
import subprocess
import sys
import time

_BOOTSTRAPPED = False


def _append_marker(status):
    marker_file = os.getenv("OPENCLAW_PYTHON_OTEL_MARKER_FILE", "")
    if not marker_file:
        return
    try:
        with open(marker_file, "a", encoding="utf-8") as handle:
            handle.write(
                f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
                f"pid={os.getpid()} status={status} argv0={sys.argv[0] if sys.argv else ''}\n"
            )
    except Exception:
        pass


def _command_text(command):
    if isinstance(command, (list, tuple)):
        parts = [str(part).strip() for part in command]
        text = " ".join(part for part in parts if part)
    else:
        text = str(command).strip()
    return text[:512]


def _flush_provider():
    try:
        from opentelemetry import trace

        provider = trace.get_tracer_provider()
        force_flush = getattr(provider, "force_flush", None)
        if callable(force_flush):
            force_flush(5000)
        shutdown = getattr(provider, "shutdown", None)
        if callable(shutdown):
            shutdown()
    except Exception:
        pass


def _instrument_subprocess():
    try:
        from opentelemetry import trace
        from opentelemetry.trace import Status, StatusCode
    except Exception as exc:
        _append_marker(f"subprocess_patch_skipped error={type(exc).__name__}:{exc}")
        return

    original_run = subprocess.run
    if getattr(original_run, "__openclaw_otel_wrapped__", False):
        return

    tracer = trace.get_tracer("openclaw.python.helper")

    def traced_run(*popenargs, **kwargs):
        command = kwargs.get("args", popenargs[0] if popenargs else "")
        with tracer.start_as_current_span("python.subprocess.run") as span:
            span.set_attribute("process.command", _command_text(command))
            span.set_attribute("subprocess.shell", bool(kwargs.get("shell", False)))
            try:
                result = original_run(*popenargs, **kwargs)
            except BaseException as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                raise
            return_code = int(getattr(result, "returncode", 0))
            span.set_attribute("subprocess.returncode", return_code)
            if return_code != 0:
                span.set_status(Status(StatusCode.ERROR, f"returncode={return_code}"))
            return result

    traced_run.__openclaw_otel_wrapped__ = True
    subprocess.run = traced_run


def _emit_startup_span():
    try:
        from opentelemetry import trace
    except Exception as exc:
        _append_marker(f"startup_span_skipped error={type(exc).__name__}:{exc}")
        return

    tracer = trace.get_tracer("openclaw.python.helper")
    with tracer.start_as_current_span("python.helper.startup") as span:
        span.set_attribute("process.pid", os.getpid())
        span.set_attribute("process.command", _command_text(sys.argv))
        span.set_attribute("process.executable.name", os.path.basename(sys.executable))


def _bootstrap():
    global _BOOTSTRAPPED
    if _BOOTSTRAPPED:
        return
    _BOOTSTRAPPED = True

    try:
        from splunk_otel import init_splunk_otel

        init_splunk_otel()
    except Exception as exc:
        _append_marker(f"init_failed error={type(exc).__name__}:{exc}")
        return

    _instrument_subprocess()
    _emit_startup_span()
    atexit.register(_flush_provider)
    _append_marker("loaded")


try:
    _bootstrap()
except Exception as exc:
    _append_marker(f"bootstrap_failed error={type(exc).__name__}:{exc}")
