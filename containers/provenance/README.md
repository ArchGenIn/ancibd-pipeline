This folder stores build provenance for the container image:
- sha256 checksum of the built .sif
- apptainer inspect output
- pip freeze from inside the image

These are safe to commit (small, textual) and help reproducibility.
