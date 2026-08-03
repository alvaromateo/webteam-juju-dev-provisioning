import shutil
import subprocess
import sys


def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def run(
    cmd: list[str], *,
    input: str | None = None,
    check: bool = False,
    text: bool = True,
    timeout: int | None = None
) -> tuple[int, str, str]:
    """
    Run a command, capturing output. Never raises on non-zero unless check.
    """
    try:
        result = subprocess.run(
            cmd,
            input=input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=check,
            text=text,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        die(f"command timed out: {' '.join(cmd)}")
    except FileNotFoundError:
        die(f"command not found: {cmd[0]}")

    # this will never be reached, but stops the linter from complaining
    return (1, "", "")


def require(tool: str, hint: str) -> None:
    if shutil.which(tool) is None:
        die(f"required tool '{tool}' not found. {hint}")

def system_has(tool: str) -> bool:
    return shutil.which(tool) is not None
