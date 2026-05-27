# Parameterization of `ancIBD` by `ancibd-pipeline` for the 2026 `variants/AF_ALL` runs

This note documents the effective `ancIBD` settings used for the 2026 IBD calls that used the HDF5 sample allele-frequency field, `variants/AF_ALL`, as routed through `ancibd-pipeline`.

Relevant code paths:

- `ancibd-pipeline/scripts/call_ibd_chrom.py`
- `ancibd-pipeline/scripts/run_batchpair.sh`
- `ancibd-pipeline/scripts/run_summary.sh`
- `ancIBD/package/ancIBD/run.py`
- `ancIBD/package/ancIBD/ancIBD_summary.py`
- `ancIBD/package/ancIBD/IO/ind_ibd.py`

## 1. Chromosome-wise IBD calling

`ancibd-pipeline` calls `ancIBD.run.hapBLOCK_chroms()` from `scripts/call_ibd_chrom.py`.

For this analysis, the effective call was:

```python
hapBLOCK_chroms(
    folder_in=folder_in,
    iids=iids,
    run_iids=run_iids,
    ch=int(args.ch),
    folder_out=str(out_dir),
    output=False,
    prefix_out="",
    logfile=False,
    l_model="h5",
    e_model="haploid_gl2",
    h_model="FiveStateScaled",
    t_model="standard",
    p_col="variants/AF_ALL",
    ibd_in=1,
    ibd_out=10,
    ibd_jump=400,
    min_cm=6.0,
    cutoff_post=0.99,
    max_gap=0.0075,
)
```

### 1.1 Meaning of the main run-specific arguments

- `folder_in=folder_in`: input HDF5 location for the chromosome being processed
- `iids=iids`: loaded individual IDs
- `run_iids=run_iids`: IID pairs selected for analysis
- `ch=int(args.ch)`: chromosome number
- `folder_out=str(out_dir)`: output directory for chromosome-wise TSV files
- `p_col="variants/AF_ALL"`: allele-frequency field read from the HDF5
- `min_cm=6.0`: minimum called IBD segment length in cM

### 1.2 Explicitly passed model and threshold settings

The wrapper also passes the following settings explicitly:

- `output=False`
- `prefix_out=""`
- `logfile=False`
- `l_model="h5"`
- `e_model="haploid_gl2"`
- `h_model="FiveStateScaled"`
- `t_model="standard"`
- `ibd_in=1`
- `ibd_out=10`
- `ibd_jump=400`
- `cutoff_post=0.99`
- `max_gap=0.0075`

### 1.3 Parameters left at upstream defaults

The following `hapBLOCK_chroms()` arguments were not overridden by the pipeline for this analysis and therefore remained at the upstream defaults defined in `ancIBD/package/ancIBD/run.py`:

```python
p_model="hapROH"
ibd_jump2=0.5
IBD2=False
cutoff_post2=0.975
min_cm2_init=1.0
min_cm2_after_merge=2.0
mask=""
```

## 2. Summary generation

After chromosome-wise calling, `ancibd-pipeline` runs `ancIBD-summary` in:

- `scripts/run_batchpair.sh` for per-job summaries
- `scripts/run_summary.sh` for the final merged summary

The pipeline passes:

```bash
ancIBD-summary \
  --tsv <base path to per-chromosome TSVs> \
  --ch <chromosome range> \
  --out <output directory>
```

No explicit values were passed for `--bin`, `--snp_cm`, or `--IBD2` in this analysis.

## 3. Effective `ancIBD-summary` settings

Given the implementation in `ancIBD/package/ancIBD/ancIBD_summary.py`, the effective behaviour was equivalent to:

```python
combine_all_chroms(
    chs=chs,                          # derived from --ch
    folder_base=tsv_base_path,        # derived from --tsv
    path_save=out_dir / "ch_all.tsv", # derived from --out
)

create_ind_ibd_df(
    ibd_data=out_dir / "ch_all.tsv",
    min_cms=[8, 12, 16, 20],
    snp_cm=220,
    min_cm=8,
    sort_col=0,
    savepath=out_dir / "ibd_ind.tsv",
    output=True,
)
```

Both functions are defined in `ancIBD/package/ancIBD/IO/ind_ibd.py`. An equivalent explicit `ancIBD-summary` command would be:

```bash
ancIBD-summary \
  --tsv <base path to per-chromosome TSVs> \
  --ch <chromosome range> \
  --bin '8,12,16,20' \
  --snp_cm 220 \
  --out <output directory>
```
