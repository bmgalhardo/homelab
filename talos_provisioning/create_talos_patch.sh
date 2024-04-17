#!/bin/bash

output=templates/cilium_patch.yml
cilium_folder=../infrastructure/cilium

cat ${cilium_folder}/cilium_template.yml > $output && kubectl kustomize $cilium_folder --enable-helm | sed 's/^/      /' >> $output

echo file $output created..
