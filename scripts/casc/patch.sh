#! /bin/bash
JENKINS_YAML=${1:-"jenkins.yaml"}
cp -f $JENKINS_YAML $JENKINS_YAML.bak
cat $JENKINS_YAML | yq e  'del(.unclassified.gitHubPluginConfig, .unclassified.location, .unclassified.operationsCenterRootAction, .jenkins.agentProtocols, .license, .jenkins.labelAtoms, .jenkins.remotingSecurity, .jenkins.slaveAgentPort, .jenkins.updateCenter, .credentials, .unclassified.quietStartConfiguration, .unclassified.gitHubPluginConfig)'  | tee patched-jenkins.yaml
diff patched-jenkins.yaml $JENKINS_YAML
