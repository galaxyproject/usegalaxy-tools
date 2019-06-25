# usegalaxy.\* tools

**WORK IN PROGRESS**

[![Build Status](https://travis-ci.org/galaxyproject/usegalaxy-tools.svg?branch=master)](https://travis-ci.org/galaxyproject/usegalaxy-tools)

## Setup

- `yaml` files are manually curated
- `yaml.lock` files are automatically generated
- Only IUC tools are automatically updated with the latest version each week
- Use the provided `requirements.txt` to install dependences needed for the make targets

### Updating an Existing Tool

1. Edit the .yaml.lock file to add the latest/specific changeset revision for the tool. You can use `python scripts/update-tool.py --owner <repo-owner> --name <repo-name> <file.yaml.lock>` in order to do this if you just want to add the latest revision.
2. Open a pull request

### Requesting a New Tool

- If you just want the latest version:
	- Edit the .yaml file to add name/owner/section
- If you want a specific version:
	- Edit the .yaml file to add name/owner/section
	- Run `make fix`
	- Edit the .yaml.lock to correct the version number.
- Open a pull request

### Tips

Use `make TOOLSET=<toolset_dir> <target>` to limit a make action to a specific toolset subdirectory, e.g.:

```console
$ make TOOLSET=usegalaxy.org lint
find ./usegalaxy.org -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/fix-lockfile.py
find ./usegalaxy.org -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 -I{} pykwalify -d '{}' -s .schema.yml
 INFO - validation.valid
 INFO - validation.valid
 ...
```
