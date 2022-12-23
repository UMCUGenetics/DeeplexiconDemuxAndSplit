# DeeplexiconDemuxAndSplit
Wrapper pipeline script running demux and split on nanopore fast5 and fastq data using the Deeplexicon pipeline

See the Deeplexicon github for extended information:
https://github.com/Psy-Fer/deeplexicon

## Installing and setup

The script currently assumes a slurm cluster and singularity images.

The docker image can be downloaded from: https://hub.docker.com/r/lpryszcz/deeplexicon

Pull as a singularity img: 
```
singularity pull docker://lpryszcz/deeplexicon:1.2.0
```

Adjust the following lines in the script to match the final location of the singularity img and mail address to be used for job information.

```
EMAIL="name@mail.com"
SINGULARITY_IMG="/path/to/deeplexicon_1.2.0.sif"
```

## Summary

The script basically works in 3 steps.

1. Predict the barcodes based on the fast5 files in the nanopre run folder, this is done for each fast5 file in parallel for fastest processing
2. Concatenate the resulting files from 1) as well as all the seperate fastq.gz files in nanopore run folder for final processing
3. Split the fastq file based on the barcodes found and recorded in the tsv files

The wrapper script sets up scripts for each of these steps and executes them so that all are ran in the proper order and also only when the previous steps are finished.

## Execution

The script is ran in the following way, the supplied parameters are obligatory:

```
deeplexicon_prepare_array.sh -i /path/to/fast5_pass -o /path/to/output
```

At least the path to the passed fast5 files as well as the output folder must be specified. Optionally a folder to the corresponding passed fastq files can be supplied, if not it will look in the parent folder of the fast5_pass folder and look for a fastq_pass folder in there.

The script will show the progress of creating the variouos subscripts and finally submit the 'submission script'.

