#!/usr/bin/env python3
import argparse
import os
import sys

def create_skill(name, description):
    # Determine the skills directory (parent of current script's parent)
    # script is in <root>/skills/learning/scripts/create_skill.py
    # so we want <root>/skills/<name>
    
    current_dir = os.path.dirname(os.path.abspath(__file__))
    skills_root = os.path.abspath(os.path.join(current_dir, "../../"))
    
    skill_dir = os.path.join(skills_root, name)
    scripts_dir = os.path.join(skill_dir, "scripts")
    
    if os.path.exists(skill_dir):
        print(f"Error: Skill '{name}' already exists at {skill_dir}")
        sys.exit(1)
        
    try:
        os.makedirs(scripts_dir)
        print(f"Created directory: {skill_dir}")
        print(f"Created directory: {scripts_dir}")
        
        # improved metadata formatting for OpenClaw
        metadata_json = '{"openclaw": {"emoji": "✨", "requires": {"bins": [], "env": []}}}'
        
        skill_md_content = f"""---
name: {name}
description: {description}
metadata: {metadata_json}
---

# {name.replace('-', ' ').title()}

{description}

## Actions

"""
        with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
            f.write(skill_md_content)
            
        print(f"Created SKILL.md for {name}")
        
    except Exception as e:
        print(f"Error creating skill: {e}")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create a new OpenClaw skill")
    parser.add_argument("--name", required=True, help="Name of the skill (folder name)")
    parser.add_argument("--description", required=True, help="Description of the skill")
    
    args = parser.parse_args()
    create_skill(args.name, args.description)
