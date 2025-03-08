# usegalaxy.\* tools

This repository maintains toolset for the https://usegalaxy.org Galaxy instance. Using this anyone can request installation of a new tool.
Additionally this repository can be used to outfit your own Galaxy with the same toolset.

[Requesting a new tool](#requesting-a-new-tool)
[Loading tools in your Galaxy](#loading-tools-in-your-galaxy)

## Setup

- `yaml` files contain the names of Tool Shed repositories to install and are **manually** curated
- `yaml.lock` files are **automatically** generated
- All tools are automatically updated with the latest version periodically
- Use the provided `requirements.txt` to install dependences needed for the `make` targets

## Requesting a new tool

*Anyone* can request tool installation on [usegalaxy.org](https://usegalaxy.org/) or [test.galaxyproject.org](https://test.galaxyproject.org).
In the commands below fill the `{server_name}` as appropriate (usegalaxy.org, test.galaxyproject.org)

1. Fork and clone [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
1. Create/activate a virtualenv and `pip install -r requirements.txt`
1. You are either installing a new repo or updating existing repo
1. If this is a new a section without an existing yml file create a new one like this:
    1. Determine the desired section label
    1. Normalize the section label to an ID/filename with [this process](https://github.com/galaxyproject/usegalaxy-tools/issues/9#issuecomment-500847395)
    1. Create `{server_name}/<section_id>.yml` setting `tool_panel_section_label` from the section label obtained in previous step (see existing yml files for exact syntax)
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