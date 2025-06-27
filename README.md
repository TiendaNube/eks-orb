# EKS Orb
Orb for installing the tools to interact with Amazon Elastic Container Service for Kubernetes (EKS) from within a
CircleCI build job.

## Usage

### Setup required to use this orb
The following **required** dependencies must be configured in CircleCI in order to use this orb:

#### Include ORBs
```yml
orbs:
  aws-ecr: circleci/aws-ecr@9.3.7
  eks: tiendanube/eks@1.8.1
```

#### Add jobs execution
```yml
        - eks/helm-deploy:
          name: prd-eks-deployment
          pre-steps:
            - aws-cli/setup:
                role_arn: "arn:aws:iam::201009178507:role/CircleCIRoleForOIDC_Generic"
                region: ${AWS_REGION_STAGING}
          context: microservices
          cluster-name: staging
          region: ${AWS_REGION_STAGING}
          s3-chart-repo: tiendanube-charts
          release-name: ${CIRCLE_PROJECT_REPONAME}-${CIRCLE_BRANCH}
          values-file: values-staging.yaml
          namespace: ${CIRCLE_PROJECT_REPONAME}
          chart: tiendanube-charts/microservices-v6
          image-tag: stg-${CIRCLE_SHA1:0:7}
          ...
```


## Useful commands to work with ORB code
### Validate ORB
- Make sure you're on the main branch of the source repository.
- From the root of the project, package the ORB content by running:

```bash
circleci orb pack src > orb.yml
```

- Validate the syntax of the generated file:

```bash
circleci orb validate orb.yml
```

### Publish a development version/release candidate of the ORB

```bash
circleci orb publish orb.yml tiendanube/eks@dev:first
```

### Release an official productive version
Ask the Productivity-Engineer team to perform the official release using:

```bash
circleci orb publish promote tiendanube/eks@dev:first patch --token 'value from orbs-token context'
```

**Note:** The version parameter can be one of:
- `patch` - for bug fixes and minor changes (1.0.0 → 1.0.1)
- `minor` - for new features (1.0.0 → 1.1.0) 
- `major` - for breaking changes (1.0.0 → 2.0.0)

You can check the published version here: https://app.circleci.com/settings/organization/github/TiendaNube/orbs

### View in the orb registry
See the [eks-orb in the registry](https://circleci.com/orbs/registry/orb/tiendanube/eks)
for more the full details of jobs, commands, and executors available in this ORB.
Or check via CircleCI CLI using:
```bash
circleci orb info tiendanube/eks@1.8.0
```
