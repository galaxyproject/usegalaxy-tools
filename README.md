# usegalaxy.\* tools

**WORK IN PROGRESS**

## Setup

- `yaml` files are manually curated
- `yaml.lock` files are automatically generated
- Only IUC tools are automatically updated with the latest version each week

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

## For UseGalaxy.\* Instance Administrators

Set the environment variables `GALAXY_SERVER_URL` and `GALAXY_API_KEY` and run `make install`. This will install ALL of the tools from the .lock files. Be sure that the tool panel sections are pre-existing or it will make a mess of your tool panel. You can run `grep -o -h 'tool_panel_section_label:.*' *.yaml.lock | sort -u` for a list of categories.
