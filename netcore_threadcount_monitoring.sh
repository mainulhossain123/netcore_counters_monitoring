#!/bin/bash
#
# This script is for monitoring the number of threads of a .NET core application.
# If the thread count exceeds a predefined threshold, then the script will automatically generate a memory dump for investigation.
#
# author: Tuan Hoang
# 28 May 2024
script_name=${0##*/}
function usage() {
    echo "###Syntax: $script_name -t <threshold>"
    echo "- Without specifying -t <threshold>, the default will be 100 threads."
    echo "###Threshold: when the number of threads exceeds the threshold value in the working instance, the script will automatically take a memory dump for that instance."
}
function die() {
    echo "$1" >&2
    exit $2
}
function getcomputername()
{
    # $1-pid
    instance=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}
function getsasurl()
{
    # $1-pid
    sas_url=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}
while getopts ":t:hc" opt; do
    case $opt in
        t)
           threshold=$OPTARG
           ;;
        h)
           usage
           exit 0
           ;;
        c)
           clean_flag=1
           ;;
        *)
           die "Invalid option: -$OPTARG" 1
           ;;
    esac
done
shift $(( OPTIND - 1 ))
# Cleaning all processes generated by the script
if [[ "$clean_flag" -eq 1 ]]; then
    echo "Shutting down dotnet-counters collect process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-counters" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down $script_name process..."
    kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Finishing up..."
    echo "Completed"
    exit 0
fi
# Define default threshold value for the number of threads
if [[ -z "$threshold" ]]; then
    echo "###Info: If not specify the option -t <threshold>, the script will set the default threshold of thread counts to 100"
    threshold=100
fi
# Find the PID of the .NET application
pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
  die "There is no .NET process running" 1
fi
# Get the computer name from /proc/PID/environ, where PID is .net core process's pid
instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find the environment variable of COMPUTERNAME" >&2 1
fi
# Get sas url
sas_url=$(getsasurl "$pid")
# Output dir is named after instance name
output_dir="threadcount-logs-$instance"
# Create output directory if it doesn't exist
mkdir -p "$output_dir"
# name of the file storing output of dotnet-counters collect
runtime_counter_log_file="dotnet-runtime-metrics-$instance.csv"

# name of the lock file for generating memdump
dump_lock_file="dump_taken.lock"

# Collect the .NET process' runtime metrics by starting the dotnet-counters collect command in background
/tools/dotnet-counters collect --process-id "$pid" --counters System.Runtime --output "$runtime_counter_log_file" > /dev/null &

# Wait until the dotnet-counters collect start writing its collected data to the output file
while [[ ! -e "$runtime_counter_log_file" ]]; do
   sleep 1
done

# Function to truncate collected metric data file
# syntax: trunc <filename>
trunc() {
    MAX_SIZE=$(( 1*1024*1024 )) # 1 MB
    while [[ -f "$1" ]]; do
        file_size=$(stat -c%s "$1")
        if [[ "$file_size" -ge "$MAX_SIZE" ]]; then
            #truncate the file
            truncate -s 0 "$1"
        fi
    done
}
# Read the log
if [[ -e "$runtime_counter_log_file" ]]; then
    # Start a thread to monitor the size of $runtime_counter_log_file & truncate it
    trunc "$runtime_counter_log_file" &
    # Reading metric data in $runtime_counter_log_file to extract threadcount information
    tail -f "$runtime_counter_log_file" | while read -r line; do
        # Check if it's a new hour
        current_hour=$(date +"%Y-%m-%d_%H")
        if [ "$current_hour" != "$previous_hour" ]; then
            # Rotate the file
            output_file="$output_dir/threadcount_${current_hour}.log"
            previous_hour="$current_hour"
        fi
        if [[ $line == *"ThreadPool Thread Count"* ]]; then
            thread_count=$(echo "$line" | awk -F ',' '{print $NF}')
            timestamp=$(echo "$line" | awk -F ',' '{print $1}')
            echo "$timestamp: Thread Pool Thread Count: $thread_count" >> "$output_file"
            # Compare with the threshold value
            if [[ "$thread_count" -ge "$threshold" ]]; then
                if [[ ! -e "$dump_lock_file" ]]; then
                    dump_file="dump_$instance_$(date '+%Y%m%d_%H%M%S').dmp"
                    echo "The number of thread counts exceed the threshold, colleting memory dump..." >> "$output_file"
                    echo "Acquiring lock..." >> "$output_file" && touch "$dump_lock_file" && echo "Memory dump is collected by $instance" >> "$dump_lock_file"
                    /tools/dotnet-dump collect -p "$pid" -o "$dump_file" > /dev/null && \
                       echo "$(date '+%Y-%m-%d %H:%M:%S'): Memmory dump has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" && \
                       /tools/azcopy copy "$dump_file" "$sas_url" > /dev/null && \
                       echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been uploaded to Azure Blob Container 'insights-logs-appserviceconsolelogs'" &
                fi
            fi
        fi
    done
fi

