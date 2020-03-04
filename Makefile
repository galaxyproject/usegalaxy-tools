GALAXY_SERVER := https://usegalaxy.*


help:
	@egrep '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[94m%-16s\033[0m %s\n", $$1, $$2}'

lint: ## Lint all yaml files
	find ./$(TOOLSET) -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/fix-lockfile.py
	find ./$(TOOLSET) -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 -I{} pykwalify -d '{}' -s .schema.yml

fix: ## Fix all lockfiles and add any missing revisions
	@# Generates the lockfile or updates it if it is missing tools
	find ./$(TOOLSET) -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/fix-lockfile.py
	@# --without says only add those hashes for those missing hashes (zB new tools)
	find ./$(TOOLSET) -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/update-tool.py --without

#install:
	#@echo "Installing any updated versions of $<"
	#@-shed-tools install --toolsfile $< --galaxy $(GALAXY_SERVER) --api_key $(GALAXY_API_KEY)


update-trusted: ## Run the update script
	@# Missing --without, so this updates all tools in the file.
	find ./$(TOOLSET) -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/update-tool.py --owner $(OWNER)


.PHONY: lint update-trusted help fix
