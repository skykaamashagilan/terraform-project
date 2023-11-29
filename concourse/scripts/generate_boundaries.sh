#!/bin/bash

echo "Generating Boundaries.json for $job_name"


accounts=$(cat ./data/account_info.json)
accounts_length=$(echo $accounts | jq length)

python $script_name --length $accounts_length --upper-bound $upper_bound > "$job_name.json"
mv "$job_name.json" "$output_dir/$job_name.json"

