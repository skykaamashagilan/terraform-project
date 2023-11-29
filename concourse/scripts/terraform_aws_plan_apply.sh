#!/bin/bash

echo "Configuring the Git cred helper to use our creds to allow us to pull private repos"
git config --global credential.helper store
cat <<EOT >>~/.git-credentials
https://$github_username_encoded:$github_pat@github.com
EOT

if [[ $terraform_folder == "terraform/terraform-baseline-identity" ]]; then
  # Get the full path of the account yaml so the Python can reference it
  function abspath() {
    # generate absolute path from relative path
    # $1     : relative filename
    # return : absolute path
    if [ -d "$1" ]; then
      # dir
      (
        cd "$1"
        pwd
      )
    elif [ -f "$1" ]; then
      # file
      if [[ $1 = /* ]]; then
        echo "$1"
      elif [[ $1 == */* ]]; then
        echo "$(
          cd "${1%/*}"
          pwd
        )/${1##*/}"
      else
        echo "$(pwd)/$1"
      fi
    fi
  }
  account_yaml_path=$(abspath $account_yaml_path)
fi

# Get our account_info.json file and split it up into the parts required
lower_bound=$lower_bound
upper_bound=$upper_bound
accounts=$(cat ./data/account_info.json | jq -r ".[$lower_bound:$upper_bound]")
accounts_length=$(echo $accounts | jq length)

printf '%*.0s\n' 50 "" | tr " " "#"
echo "Vars/Data passed...:"
echo "Lower Bound: $lower_bound"
echo "Upper Bound: $upper_bound"
echo "Terraform folder: $terraform_folder"
echo "Accounts Found: $accounts_length"
echo ""

if [[ $accounts != '[]' ]]; then

  # Setting Terraform Env vars as we are running in automation
  export TF_IN_AUTOMATION=1
  export TF_INPUT=0

  echo "Setting the GOOGLE_CREDENTIALS environment variable..."
  export GOOGLE_CREDENTIALS=$google_credentials # Used to allow us to authenticate GCS for our Terraform State

  # Update our backend config to have the correct Bucket name
  backend_file=$(find . -wholename "*${terraform_folder}/backend.tf")
  echo "Updating our $backend_file file to have the correct bucket name of $bucket_name"
  sed -i "s/((bucket_name))/"$bucket_name"/g" $backend_file
  # cat $backend_file

  # Update our main.tf to have the correct Branch name
  main_file=$(find . -wholename "*${terraform_folder}/main.tf")
  echo "Updating our $main_file file to have the correct branch name of $branch_name"
  sed -i "s/((branch))/"$branch_name"/g" $main_file

  # Change the default IFS value to look for new lines ratehr than spaces as this causes issues with spaces in account names
  IFS=$'\n'
  # Loop through this range and do the Terraform stuff
  for ((i = 0; i < $accounts_length; i++)); do
    account_id=$(echo $accounts | jq -r ".[$i].account_id")
    account_name=$(echo $accounts | jq -r ".[$i].name")
    account_alias=$(echo $accounts | jq -r ".[$i].alias")

    printf '%*.0s\n' 50 "" | tr " " "#"
    echo "Account Name: $account_name ($i/$accounts_length)"
    printf '%*.0s\n' 50 "" | tr " " "#"

    echo "Getting a set of temporary credentials from STS to pass to Terraform"
    export AWS_ACCESS_KEY_ID="$access_key"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    role_arn="arn:aws:iam::$account_id:role/$role_name"
    aws sts assume-role --role-arn $role_arn --role-session-name "sts" --duration-seconds $sts_session_duration >./data/$account_name-creds.json

    if [ $? -eq 0 ]; then
      echo "Successfully saved credentials"
      export AWS_ACCESS_KEY_ID=$(cat ./data/$account_name-creds.json | jq -r .Credentials.AccessKeyId)
      export AWS_SECRET_ACCESS_KEY=$(cat ./data/$account_name-creds.json | jq -r .Credentials.SecretAccessKey)
      export AWS_SESSION_TOKEN=$(cat ./data/$account_name-creds.json | jq -r .Credentials.SessionToken)
    else
      exit 1
    fi

    # Get where we currently are so we can easily get back here later.
    entry=$PWD

    cd ./cec-aws-account-governance/$terraform_folder
    echo "Running Terraform init..."
    terraform init

    if [ $? -ne 0 ]; then
      echo "Error initialising Terraform. Please see the above error. Now bailing to avoid any State blurring!"
      exit 1
    fi
    terraform workspace select $account_name || terraform workspace new $account_name # Create our workspace if it does not aleady exist
    terraform init # Uncomment this if you are seeing issues with "Failed to instantiate provider...."

    # Check if there is a .tfvars file in our dir that has our $account_name
    file_check=$(find vars/ -name "$account_name.tfvars")
    if [ -z $file_check ]; then
      echo "No account specific variable file found so finding the default one..."
      default_file_check=$(find vars/ -name "default.tfvars")
      if [ -z $default_file_check ]; then
        echo "No default variable file found either. I now do not know what to do so I will bail"
        exit 1
      else
        echo "Default variable file found"
        file_name=$default_file_check
      fi

    else
      echo "Account specific variable found for $account_name"
      file_name=$file_check
    fi

    # Check if there are any outputs from previous Terrafom runs Vars that need to be exported
    echo "Checking for any JSON outputs files in the Data volume"
    outputs_check=$(find $entry -name "outputs*.json")
    if [[ ! -z $outputs_check ]]; then
      echo "Terraform outputs found. Extracting values..."
      # echo "Files found:"
      # echo -e "$outputs_check"
      # For loop here to go through each file
      for file in $outputs_check; do
        # echo "File name: $file"
        outputs=$(jq 'to_entries|map("\(.key)=\(.value.value)")|.[]' $file)
        for var in $outputs; do
          name=$(echo $var | cut -d "=" -f 1 | sed -e 's/^"//' -e 's/"$//')
          value=$(echo $var | cut -d "=" -f 2 | sed -e 's/^"//' -e 's/"$//')
          echo "Exporting new variable called $name"
          export $name=$value
        done
      done
    else
      echo "No output file found so no actions needed."
    fi

    # Check if there are any variables in the TF Vars that have ((name)) as these need dynamically updating
    echo "Checking $file_name for any special variables that need dynamically setting..."
    special_vars=$(grep '((' $file_name | cut -d" " -f1)
    if [ ! -z "$special_vars" ]; then
      echo "Found some. Looping through and updating them..."
      # Copy our tfvars file so we can update dit multiple times without affecting the original
      cp $file_name "${file_name}_${account_name}.tfvars"
      file_name="${file_name}_${account_name}.tfvars"
      for var in $special_vars; do
        echo "replacing '(($var))' in the file" #with '${!var}'"
        sed -i "s|(($var))|${!var}|g" $file_name
      done
    else
      echo "None found"
    fi

    random_number=${RANDOM:0:3}
    # Have Terraform return detailed status code so we can only apply if we need to and save time
    echo "Running Terraform plan..."
    terraform plan -out $account_name.plan -var-file=$file_name -detailed-exitcode
    exit_status=$?
    if [ $exit_status -eq 0 ]; then
      echo "No changes to be made."
      echo "Saving any outputs to ${entry}/cec-aws-account-governance/outputs_$random_number.json"
      terraform output -json >$entry/cec-aws-account-governance/outputs_${random_number}.json
    elif [ $exit_status -eq 1 ]; then
      echo "Error running Terraform plan. Please see the logs above. Now bailing..."
      exit 1
    elif [ $exit_status -eq 2 ]; then
      echo "Running Terraform apply..."
      terraform apply $account_name.plan
      if [ $? -ne 0 ]; then
        echo "Error running Terraform apply. Please see the logs above. Now bailing..."
        exit 1
      fi
      echo "Saving any outputs to ${entry}/cec-aws-account-governance/outputs_$random_number.json"
      terraform output -json >$entry/cec-aws-account-governance/outputs_${random_number}.json
    fi

    # CD back to original path and unset the exported vars so we can loop to the next account
    cd $entry
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN

  done
else
  echo "No data found in aray so nothing to do here."
  exit 0
fi
