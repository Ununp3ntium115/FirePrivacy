#!/usr/bin/env python3
"""Check macOS's Apple provisioning-profile policy without signing credentials."""
import importlib.util
from pathlib import Path
import sys


def main():
    if sys.platform != "darwin":
        print("Checking Apple's signing policy requires macOS.", file=sys.stderr)
        return 1
    try:
        spec = importlib.util.spec_from_file_location(
            "fireprivacy_cloud_signing", Path(__file__).with_name("cloud-signing.py")
        )
        signing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(signing)
    except Exception:
        print("The signing helper could not be loaded; runtime details were suppressed.", file=sys.stderr)
        return 1
    try:
        security, core, identifier = signing.apple_security_api()
        policy = security.SecPolicyCreateWithProperties(identifier, None)
        if not policy:
            raise signing.SigningError("The Apple provisioning-profile policy could not be created.")
        core.CFRelease(policy)
    except signing.SigningError as error:
        print(f"Signing policy check: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("Signing policy check failed; runtime details were suppressed.", file=sys.stderr)
        return 1
    print("Apple's provisioning-profile trust policy is available on this macOS runtime.")
    print("A real Apple profile is still required to verify its signature and signer trust.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
