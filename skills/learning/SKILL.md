---
name: learning
description: Meta-skill that allows the agent to learn new capabilities by creating other skills and actions.
metadata: {"openclaw": {"emoji": "🎓", "requires": {"bins": ["python3"], "env": []}}}
---

# Learning Skill

This skill empowers the agent to "learn" new capabilities by authoring new skills and actions for itself. When you encounter a repetitive task or a problem that requires a specific tool, use this skill to create that tool for future use.

## Actions

### Create Skill

Scaffold a new empty skill. Use this when you want to group a new set of related capabilities (e.g., "jira-tools", "math-solver").

```bash
{baseDir}/scripts/create_skill.py --name "skill-name" --description "Description of what this skill does"
```

### Implement Action

Add a specific action (tool) to an existing skill.

```bash
{baseDir}/scripts/implement_action.py --skill "skill-name" --action "action_name" --description "What this action does" --code "script content"
```

### Search Skills

Search for existing skills on ClawHub (public registry) or local discovery. Always checking "buy vs build" first.

```bash
{baseDir}/scripts/search_skills.py --query "query string"
```

### Install Skill

Install a skill from ClawHub or a git repository.

```bash
{baseDir}/scripts/install_skill.py --slug "skill-slug-or-url"
```

### List Skills

See what skills are currently installed and available to be extended.

```bash
ls -F ../
```
