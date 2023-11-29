#!/bin/bash

# Read in the 2 script names passed and add them to an array so we can reference them in the below Python call
IFS=', ' read -r -a scripts <<< "$script_names"

echo "Calling Python to get the deployment info we need"
python "$script_path/${scripts[1]}" --deployment-name "$deployment_name" --deployment-folder-path "$deployment_folder_path"

if [[ $(cat "deployment-config.json" | jq -r ".path") == "ALL" ]]; then
  path=$(cat "deployment-config.json" | jq -r ".path" | awk 'NR > 1 { printf(" ") } {printf "%s",$0}')
else
  path=$(cat "deployment-config.json" | jq -r '.path | join(" ")')
fi

printf '%*.0s\n' 50 "" | tr " " "#"
echo ""

echo "Calling Python to get the account information we need"
python "$script_path/${scripts[0]}" --yaml-file-path "./aws-account-info/accounts.yml" \
    --aws-access-key-id "$access_key" --aws-secret-access-key "$secret_key" --filter $path

if [ $? -eq 0 ]
then
  echo "Moving our account info file to the output volume so we can get it in the next Task(s)"
  # cat account_info.json
  mv account_info.json ./data
else
  exit 1
fi