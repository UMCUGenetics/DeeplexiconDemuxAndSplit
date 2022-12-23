#!/bin/bash
#set -euo pipefail

HELP="0"
EMAIL="name@mail.com"
SINGULARITY_IMG="/path/to/deeplexicon_1.2.0.sif"

#Show usage info if no arguments specified
if [[ $# -eq 0 ]]; then
	HELP="1"
fi

#initialize parameters
COMPUTE_GROUP="ubec"
output_folder=""
fast5_path=""
fastq_path=""
batch_size=1

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell

while getopts "i:q:o:g:b:h" opt; do
  case $opt in
    i)
      fast5_path=$OPTARG
      ;;
    q)
      fastq_path=$OPTARG
      ;;
    o)
      output_folder=$OPTARG  
      ;;
    g)
      COMPUTE_GROUP=$OPTARG  
      ;;
    b)
      batch_size=$OPTARG  
      ;;
    h)
      HELP="1"
      ;;

    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [[ "$HELP" == "1" ]]; then
	echo "# Usage: "
	echo "# deeplexicon_prepare_array.sh <options>"
	echo "#"
	echo "# Where the following options are available: "
	echo "# -i </path/to/input>"
	echo "# 	The path where the fast5 files to be demultiplexed can be found"
	echo "# -q </path/to/fastq>"
	echo "# 	The path where the seperate fastq files to be combined can be found"
	echo "# 	Uses -i replacing fast5_pass with fastq_pass if not specified..."
	echo "# -o </path/to/output>"
	echo "# 	Path where the results should be stored. "
	echo "# 	./<basename_input_folder>_output/ if not specified..."
	echo "# -b <size>"
	echo "# 	The size of batches in which to process the fast5 files"
	echo "# 	Due to lack of multithreading paralel processing is most efficient"
	echo "# 	Default: 1"
	echo "# -g <compute_group>"
	echo "# 	Override compute group used to reserve computing power"
fi

#path with (passed) fast5 files
if [[ "$fast5_path" == "" ]]; then
	echo "No fast5 input path specified... exiting!"
	exit
fi

if [[ ! -d $fast5_path ]]; then
	echo "Invalid fast5 path: ${fast5_path}. Exiting!"
	exit
fi

#path with (passed) fast5 files
if [[ "$fastq_path" == "" ]]; then
	fastq_path="${fast5_path/fast5_pass/fastq_pass}"
	echo "No fastq path specified... Trying ${fastq_path}."
	if [[ ! -d $fastq_path ]]; then
		echo "Invalid fastq path: ${fastq_path}. Exiting!"
		exit
	fi
fi

#use name of fast5 folder as base for output folder (in current working folder)
if [[ "$output_folder" == "" ]]; then
	output_folder="`basename $fast5_path`_output"
	echo "# No output path specified... Using: ${output_folder}"
fi

fast5_path=`realpath $fast5_path`
fastq_path=`realpath ${fastq_path}`
output_folder=`realpath $output_folder`
run_name=`basename $output_folder`
batch_script_1="${output_folder}/1_${run_name}_submit_demux_barcode_predict.sh"

if [[ "$batch_size" != "1" ]]; then
	echo "Batchsizes other then 1 don't work properly yet, defaulting to 1..."
	batch_size=1
fi

echo ""
echo "### Running demultiplexing with: "
echo ""
echo "# Fast5 input folder: ${fast5_path}"
echo "# Fastq input folder: ${fastq_path}"
echo "# Output folder: ${output_folder}"
echo "# Batch size: ${batch_size}"
echo ""

if [[ ! -d $output_folder ]]; then mkdir -p $output_folder; fi
mkdir -p $output_folder/input
mkdir -p ${output_folder}/demuxed 
mkdir -p ${output_folder}/log_1/
mkdir -p ${output_folder}/log_2/
mkdir -p ${output_folder}/log_3/

nr_ids=`ls ${fast5_path}/*.fast5 | cut -f1 -d"_" | sort | uniq | wc -l`

if [[ "$nr_ids" == "1" ]]; then
	samplename=`ls ${fast5_path}/*.fast5 | xargs basename -a | cut -f1 -d"_" | sort | uniq`
else
	samplename="${run_name}"
fi

###
### Script 1, barcode prediction (demux)
###

echo "### Step 1, prepare scripts for barcode prediction (demux) step... (Might take a while)"

# Determine nr of jobs needed
arraycount=`ls ${fast5_path}/*.fast5 | wc -l`

# Create array config file
echo "# Create config file for ${arraycount} jobs..."

index=1
array_config_file="$output_folder/input/${samplename}_array.config"

echo "ArrayTaskID	fast5_folder" > $array_config_file

find $fast5_path -iname "*.fast5" | while read line; do	
	filename=`basename $line`
	if [[ $batch_size -eq 1 ]]; then
		foldername="${filename%.*}"
	fi

	#folder for specific fast5 file
	fast5_folder="${output_folder}/input/${foldername}"
	mkdir -p $fast5_folder
	#cp $line $fast5_folder/
	ln -s $line $fast5_folder/
	
	#add to config
	echo "$index	$fast5_folder" >> $array_config_file

	#if [[ $index -eq $batch_size ]]; then 
	#	index=0
	#	batch=$((batch+1))	
	#	foldername="fast5_batch_${batch}"
	#fi
	index=$((index+1))
done

echo "# Create bash script... $batch_script_1"

echo "#!/bin/bash
#SBATCH --time=03:00:00
#SBATCH --mem 10G
#SBATCH --gres=tmpspace:10G
#SBATCH --job-name="${run_name}_1_demux"
#SBATCH -o ${output_folder}/log_1/demux_task_%a.%j.out
#SBATCH -e ${output_folder}/log_1/demux_task_%a.%j.err
#SBATCH --account=$COMPUTE_GROUP
#SBATCH --array=1-${arraycount}

#specify config file
config=${array_config_file}

#set variables for this job
fast5_folder=\`awk -v ArrayTaskID=\$SLURM_ARRAY_TASK_ID '\$1==ArrayTaskID {print \$2}' \$config\`
foldername=\`basename \$fast5_folder\`

#mount specific fast5 folder for further processing and also the input path (because of symlinks)
singularity run --bind ${fast5_path}:${fast5_path} \\
	--bind $output_folder/input/:$output_folder/input/ \\
	${SINGULARITY_IMG} deeplexicon_multi.py dmux \\
	--threads 2 \\
	-p \$fast5_folder \\
	-m /deeplexicon/models/resnet20-final.h5 \\
	> \${fast5_folder}/\${foldername}.demux2.tsv

# check status of last command, 0 means TRUE (success), 1 means FALSE (failed)
if [ \$? -eq 0 ]; then
    touch ${output_folder}/log_1/demux_\${SLURM_ARRAY_TASK_ID}.done
    echo \"Demux barcode prediction task \${SLURM_ARRAY_TASK_ID}, folder \${foldername} done.\"
    exit 0
else
    echo \"Demux barcode prediction task \${SLURM_ARRAY_TASK_ID}, folder \${foldername} failed.\"
    touch ${output_folder}/log_1/demux_\${SLURM_ARRAY_TASK_ID}.failed
    exit 1
fi
" > $batch_script_1

echo ""
echo "# Finished, run following batch script for submission: $batch_script_1"
echo "# NOTE! Sbatch must be used to succesfully submit (using bash will result in hanging or an error): "
echo "sbatch ${batch_script_1}"
echo ""

###
### Script 2, concatenate results from Script 1 as well as the seperate fastq files.
###

echo "### Step 2, prepare script for concatenating barcode info from step 1 as well as the seperate fastq files."

batch_script_2="${output_folder}/2_${run_name}_concat_tsv.sh"
tsv_path="${output_folder}/input/"
combined_tsv="${output_folder}/input/${run_name}_concat.tsv"
combined_fastq="${tsv_path}/${samplename}_combined.fastq"

echo "#!/bin/bash
#SBATCH --time=02:00:00
#SBATCH --mem 10G
#SBATCH --gres=tmpspace:10G
#SBATCH --job-name ${run_name}_2_concat
#SBATCH -o ${output_folder}/log_2/${run_name}_concat_.%j.out
#SBATCH -e ${output_folder}/log_2/${run_name}_concat_.%j.err
#SBATCH --mail-user $EMAIL
#SBATCH --mail-type FAIL,END
#SBATCH --account=$COMPUTE_GROUP

#first validate if all jobs succeeded succesfully
nr_done=\`find ${output_folder}/log_1/ -iname \"*.done\" -type f | wc -l\`
nr_jobs=\`ls ${fast5_path}/*.fast5 | wc -l\`
nr_failed=\`find ${output_folder}/log_1/ -iname \"*.failed\" -type f | wc -l\`

echo \"Fast5 count: \${nr_jobs}\"
echo \"Jobs succeeded: \${nr_done}\"
echo \"Jobs failed: \${nr_failed}\"

if [[ \$nr_failed -gt 0 ]]; then
	echo \"The following jobs failed, please make sure they run succesfully before continuing\"
	find ${output_folder}/log_1/ -iname \"*.failed\" -type f
	exit
elif [[ \$nr_jobs -eq \$nr_done ]]; then
	echo \"Not all jobs seem to be finished succesfully, please check this first!\"
	exit
fi

echo 'Concatenating tsv files...'
print_header=1
find $tsv_path -iname \"*.demux2.tsv\" | while read line; do
	#print header
	if [[ \${print_header} -eq 1 ]]; then
		head -n1 \${line} > ${combined_tsv}
		print_header=0
	fi
	#print content
	tail -n+2 \${line} >> ${combined_tsv}
done

# also concat the fastq data
echo 'Done! Concatenating fastq.gz files...'
cat ${fastq_path}/*.fastq.gz > ${combined_fastq}.gz
echo 'Done! Extracting to fastq for further processing..'
gunzip ${combined_fastq}.gz
echo 'Done!'

if [ \$? -eq 0 ]; then
    touch ${output_folder}/log_2/${run_name}_concat.done
    echo 'Splitting done.'
    echo 'Step 2: Deeplexicon concatenation completed successfully.'
    exit 0
else
    echo 'Step 2: Deeplexicon concatenation failed!.'
    touch ${output_folder}/log_2/${run_name}_concat.failed
    exit 1
fi
" > $batch_script_2

echo ""
echo "# Finished, run following script for submission: "
echo "  ${batch_script_2}"
echo ""

###
### Script 3, Actually run demuxing using results from before.
###

echo "### Step 3, prepare script actually running demuxing using output from step 1 and 2."

batch_script_3="${output_folder}/3_${run_name}_demux_split.sh"

echo "#!/bin/bash
#SBATCH --time=2:00:00
#SBATCH --nodes=2
#SBATCH --mem 15G
#SBATCH --gres=tmpspace:15G
#SBATCH --job-name ${run_name}_3_split
#SBATCH -o ${output_folder}/log_3/${run_name}_split_.%j.out
#SBATCH -e ${output_folder}/log_3/${run_name}_split_.%j.err
#SBATCH --mail-user $EMAIL
#SBATCH --mail-type FAIL,END
#SBATCH --account=$COMPUTE_GROUP

singularity run --bind ${fast5_path}:${fast5_path} \\
	--bind ${output_folder}:${output_folder} \\
	${SINGULARITY_IMG} deeplexicon_multi.py split \\
	-i ${combined_tsv} \\
	-o ${output_folder}/demuxed \\
	-s ${samplename} \\
	-q ${combined_fastq}

# check status of last command, 0 means TRUE (success), 1 means FALSE (failed)
if [ \$? -eq 0 ]; then
    echo 'Step 3: Deeplexicon split completed successfully.'
    touch ${output_folder}/log_3/${run_name}_split.done
    exit 0
else
    echo 'Step 3: Deeplexicon split failed!'
    touch ${output_folder}/log_3/${run_name}_split.failed
    exit 1
fi
" > $batch_script_3
	
echo ""
echo "# Finished, run following script for submission: "
echo "  ${batch_script_3}"
echo ""

submit_script="${output_folder}/submit_${run_name}.sh"

echo "#!/bin/bash
#submit demux job array
job_id=\$(sbatch $batch_script_1)
echo \$job_id
#fetch jobid to use in dependency
job_id=\`echo \$job_id |cut -f4 -d\" \"\`
#submit concat job, hold for arrayjob to be finished
job_id=\$(sbatch --depend=afterany:\${job_id} $batch_script_2)
echo \$job_id
job_id=\`echo \$job_id |cut -f4 -d\" \"\`
sbatch --depend=afterok:\${job_id} $batch_script_3
" > $submit_script

echo "The scripts are now prepared, executing ${submit_script} to start the pipeline..."
bash $submit_script
