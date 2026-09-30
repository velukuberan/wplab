# wplab

Local WordPress development lab for creating and managing disposable Docker environments.

## Goals

WP Lab provides isolated local WordPress environments for plugin and theme development and compatibility testing.

Each site is created as a self-contained project in the directory where it is generated.

## Planned workflow

Create a site from a configuration file:

    newsite site.json

For example:

    {
        "name": "example",
        "wordpress": "latest",
        "php": "8.3",
        "mariadb": "11"
    }

If `site.json` defines the site name as `example`, running the command from:

    ~/wordpress-projects/

creates:

    ~/wordpress-projects/example/

Created sites are registered globally so they can be discovered and managed regardless of the current working directory.

List managed sites:

    siteinfo

Destroy a site:

    killsite example

Destroying a site removes its Docker resources, project directory, and global registry entry.

## WordPress development

Generated environments are intended to support development of both:

    plugins/
    mu-plugins/

Each environment will provide its own WordPress, PHP, database, web server, and development tooling.

## Status

WP Lab is under active development.

The repository was derived from VKLab, a remote disposable testing environment. The existing infrastructure is being refactored into a local WordPress development workflow.
