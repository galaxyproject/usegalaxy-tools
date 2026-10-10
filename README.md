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
1. Create a PR against the default branch of [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
    - Use PR labels as appropriate
    - To aid PR mergers, you can include information on tools in the repo's use of `$GALAXY_SLOTS`, or even PR any needed update(s) to [Main's TPV tool config](https://github.com/galaxyproject/usegalaxy-playbook/blob/main/env/common/templates/galaxy/config/tpv/tools.yaml.j2) as explained in the "[Determine tool requirements](#determine-tool-requirements)" section once the test installation succeeds (see details below)
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

1. **The test installation runs automatically** when the PR is opened or updated (*Test tool installation*). For a PR from a fork by someone outside the organization, an authorized maintainer has to approve the run first.
2. **Review the run summary.** Just because it is green does not mean it succeeded. Open the workflow run and look for two things:
   1. **Contents of OverlayFS upper mount (will be published)** contains (at least) `config/shed_tool_conf.xml` and `shed_tools/.../the_repos_you_installed`
   2. **Diff of shed_tool_conf.xml** contains the tools in the repos you installed
3. **Merge the PR.** This triggers the *Deploy tools to CVMFS* workflow, which installs the tools again and publishes them. A bot comment on the PR reports that the deploy started, and another reports whether it succeeded.
4. **Review the deploy run summary.** Just because it is green does not mean it succeeded.
   1. Verify that the summary contains the same expected output as in the test installation,
   2. **Verify that publishing to CVMFS was successful** with this appearing toward the end of the log:
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
5. **If the deploy failed,** retry it with *Actions → Deploy tools to CVMFS →* the failed run *→ Re-run failed jobs*. If that is not possible, deployment can still be re-triggered by making a new PR with whitespace/order changes in the `.lock` file(s) modified in the original PR.
6. If these are new tools and not just new versions of already installed tools, review whether the tool uses multiple cores (the presence of `${GALAXY_SLOTS:-N}` in `<command>`) and whether increased memory is required and PR changes to [the TPV tool config](https://github.com/galaxyproject/usegalaxy-playbook/blob/main/env/common/templates/galaxy/config/tpv/tools.yaml.j2) in usegalaxy-playbook

## Tool source store

Alongside the shed tool conf, every install publishes a pre-parsed *tool source store* for the toolset at
`/cvmfs/<repo>/config/tool_source_store/v1/cvmfs_<name>.sqlite` (plus a `.manifest.json` sidecar), where `<name>` is
`test` or `main`. It is built by `build_tool_source_store` in `.ci/github-actions.sh`, which runs Galaxy's
`scripts/tool_source/populate_store.py` from the same `galaxy/galaxy-min:dev` image that installs the tools, and
which sets `store="cvmfs_<name>"` on the `<toolbox>` root of `shed_tool_conf.xml` if it is not there yet. Builds are
incremental: only tools whose files changed since the previous publish are re-parsed.

Galaxy servers ignore both the attribute and the bundle unless `use_cached_toolbox: true` is set *and* the store name
is declared in `galaxy.yml`, e.g. for Test, which loads Main's shed tool conf as well:

```yaml
use_cached_toolbox: true
tool_source_stores:
  cvmfs_test:
    external_store_directory: /cvmfs/test.galaxyproject.org/config/tool_source_store
  cvmfs_main:
    external_store_directory: /cvmfs/main.galaxyproject.org/config/tool_source_store
```

A server with `use_cached_toolbox` enabled must declare every store name referenced by the confs it loads, or it
fails to start. A bundle that is missing or was built by a Galaxy with a different tool index schema only produces
a startup warning, and that conf is parsed eagerly as before; the next install on the toolset publishes a bundle
built by the current image. The run summary contains a **Tool source store** block with the tool counts; the run
fails if the bundle was not rewritten or covers fewer than 90% of the tools in the conf.

Only approved tool installers can install tools. Request admission to the Github Team from project admins for approval.

The workflows that do this run on a self-hosted runner, because installing tools into a `fuse-overlayfs` stacked on CVMFS is not possible on GitHub-hosted runners. See [docs/self-hosted-runner.md](docs/self-hosted-runner.md) for how it is provisioned.
