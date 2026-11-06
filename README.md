# Personal Tools Collection

Reusable source tools grouped by purpose. Generated output, caches, data sets, credentials, and compiled executables are excluded.

    project-management/   PowerShell project CLI, graph source, and templates
    math-modeling/        Python environment setup, problem bootstrap, and submission checks
    media/                Portable Executable dependency inspection helper
    remote-control/       Remote Control checks, protocol schemas, and icon source

## Requirements

- Windows 10/11 and PowerShell 7 for the Windows scripts.
- Python 3.12 for the locked math-modeling environment.
- Python 3.8 or newer plus media/requirements.txt for the PE dependency checker.
- .NET SDK 8.0.425 or a later 8.0 patch for the Remote Control WebRTC smoke utility.

## Setup and use

From the repository root, install the pinned math-modeling environment:

    .\math-modeling\tools\setup-python.ps1

Install the media helper dependency once:

    py -3 -m pip install -r .\media\requirements.txt

Then invoke the desired script with its documented arguments. For example:

    py -3 .\media\tools\check_pe_dependencies.py --help
    .\remote-control\tools\validate-protocol.ps1

The math-modeling lock file is under math-modeling/requirements.lock. Each tool group keeps its own scripts and relative paths together. The register-urlacl.ps1 helper changes a Windows URL ACL; review it and its parameters before running.
