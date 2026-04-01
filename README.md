# usegalaxy.\* tools

This repository maintains the toolset for the https://usegalaxy.org Galaxy instance. Using this anyone can request installation of a new tool.
Additionally this repository can be used to outfit your own Galaxy with the same toolset.

- [Requesting a new tool](#requesting-a-new-tool)
- [Loading tools in your Galaxy](#loading-tools-in-your-galaxy)

## Setup

- `yaml` files contain the names of Tool Shed tools/repositories to install and are **manually** curated
- `yaml.lock` files are **automatically** generated and contain the list of revisions (read "tool versions") to include
- All tools are automatically updated with the latest version periodically
- Use the provided `requirements.txt` to install dependencies needed for the `make` targets
- The terms "tools" and "repositories" are used interchangeably in this readme. There is a difference, but it is not needed to be understood for using these scripts.

## Requesting a new tool

*Anyone* can request tool installation on [usegalaxy.org](https://usegalaxy.org/) or [test.galaxyproject.org](https://test.galaxyproject.org).
In the commands below fill the `{server_name}` as appropriate (usegalaxy.org, test.galaxyproject.org)

1. Fork and clone [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
1. Create/activate a virtualenv and install Python requirements with `pip install -r requirements.txt`
1. If this is a new a section without an existing yml file create a new one:
    1. Determine the desired section label
    1. Normalize the section label to an ID/filename with [this process](https://github.com/galaxyproject/usegalaxy-tools/issues/9#issuecomment-500847395)
    1. Create `{server_name}/<section_id>.yml` setting `tool_panel_section_label` from the section label obtained in previous step (see existing yml files for the exact syntax)
    1. Continue with the steps below
1. Add the entry for the new tool to the section yml (only the yml, not the yml.lock) [example](https://github.com/galaxyproject/usegalaxy-tools/pull/86/files#diff-7de70f8620e8ba71104b398d57087611R25-R26)
1. You either want the latest or a specific version
    - For latest version (most common case):
        1. Run `$ make TOOLSET={server_name} fix` (this will fill the yml.lock )
    - For a specific version (rare case):
        1. Run `$ make TOOLSET={server_name} fix-no-deps`
	    1. Edit the .yaml.lock to correct the version number.
1. Then `$ git add <file>` only the updates that you care about.
1. Run `make TOOLSET={server_name} lint`
    - Fix any issue that may arise and `git add` again
1. Commit `{server_name}/<repo>.yaml{.lock}`
1. Create a PR against the `master` branch of [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
    - Use PR labels as appropriate
    - To aid PR mergers, you can include information on tools in the repo's use of `$GALAXY_SLOTS`, or even PR any needed update(s) to [Main's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/main/templates/galaxy/config/job_conf.xml.j2) as explained in the "[Determine tool requirements](#determine-tool-requirements)" section once the test installation (via Travis) succeeds (see details below)
1. Once the PR is merged and the tool appears on [usegalaxy.org](https://usegalaxy.org/) or [test.galaxyproject.org](https://test.galaxyproject.org), test to ensure the tool works.

## Loading tools in your Galaxy

Add the following dependency resolver:

```xml
<conda prefix="/cvmfs/sandbox.galaxyproject.org/dependencies/conda" auto_install="False" auto_init="False" />
```

preferably above your existing conda dependency resolver (you will need to set `conda_auto_install: false` in your `galaxy.yml`).

And add the new shed tool conf:

```yml
tool_config_file: ...,/cvmfs/sandbox.galaxyproject.org/config/shed_tool_conf.xml
```

In your destination you should set:

```
<param id="singularity_enabled">true</param>
<param id="singularity_volumes">$defaults</param>
```

# Instructions for Tool Installers

Before proceeding with deployment, ensure the following preconditions on a PR are met:

- Tools can only be installed on one "toolset" (Galaxy instance) at a time, i.e., PRs installing to both `test.galaxyproject.org` and `usegalaxy.org` will fail.
- Test loads both its own toolbox as well as Main's, so if the intent is to install a tool on both, it should simply be added to the `usegalaxy.org` toolset.
- Tools installed to Main **must** be installed from the Main Tool Shed. Do not install tools on Main from the Test Tool Shed.
- Do not install Data Managers on Test or Main, they are not usable on our CVMFS setup.
- IUC-maintained tools (this includes `devteam` and some other repo owners) and other tools from trusted authors (e.g. `bgruening`) do not require independent review. Any other tool requires review from an experienced tool developer (which can be you, if you are one) to ensure there are no critical security, functionality, or performance bugs. These tools may also not have BioContainers available, which are required to function on Test and Main, unless the tool uses a `<container>` requirement to convert from Docker (not ideal).
- Suites cannot be installed using their `suite_` repo. Each repo in the suite must be added individually.
- The `install_*_dependencies` options at the top of the `.lock` files should all remain `false`.

Once preconditions are met:

1. Comment `@galaxybot test this` to test deployment.
2. **Review the Jenkins test console output.** Just because it is green does not mean it succeeded. You are looking for two things:
   1. **#### contents of OverlayFS upper mount (will be published)** contains (at least) `config/shed_tool_conf.xml` and `shed_tools/.../the_repos_you_installed`
   2. **#### diff of shed_tool_conf.xml** contains the tools in the repos you installed
3. Comment `galaxybot deploy this` to deploy. This will cause the **default** test on the PR to run again, and the details link for the test will be updated to a new Jenkins build.
4. **Review the Jenkins deploy console output.** Just because it is green does not mean it succeeded.
   1. Verify that the console output contains the same expected output as in the test deployment,
   2. **Verify that publishing to CVMFS was successful** with this appearing toward the end of the console output:
      ```
      # Publishing transaction on main.galaxyproject.org
      Waiting for upload of files before committing...
      Committing file catalogs...
      Swissknife Sync: Wait for all uploads to finish
      Swissknife Sync: Exporting repository manifest
      Statistics stored at: /var/spool/cvmfs/main.galaxyproject.org/stats.db
      Tagging main.galaxyproject.org
      Swissknife Sync: Processing changes...
      Creating virtual snapshots
      Waiting for upload of files before committing...
      Committing file catalogs...
      Swissknife Sync: Wait for all uploads to finish
      Swissknife Sync: Exporting repository manifest
      Statistics stored at: /var/spool/cvmfs/main.galaxyproject.org/stats.db
      Flushing file system buffers
      Signing new manifest
      Remounting newly created repository revision
      ```
      Warnings about `[WARNING] 'shed_tools/.../.wh..opq' should be deleted, but was not found in repository.` can be safely ignored.
5. Merge the PR **only after you have verified via Jenkins console output that the deployment succeeded.** If it failed, the only way to retry deployment after merge is to make a new PR with whitespace/order changes in the `.lock` file(s) modified in the original PR.
6. If these are new tools and not just new versions of already installed tools, review whether the tool uses multiple cores (the presence of `${GALAXY_SLOTS:-N}` in `<command>`) and whether increased memory is required and PR changes to the TPV config in https://github.com/galaxyproject/usegalaxy-playbook/

Only approved tool installers can install tools. Request Jenkins access and admission to the Github Team from project admins for approval.
