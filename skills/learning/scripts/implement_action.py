#!/usr/bin/env python3
import argparse
import os
import sys

def implement_action(skill_name, action_name, description, code):
    # Determine paths
    current_dir = os.path.dirname(os.path.abspath(__file__))
    skills_root = os.path.abspath(os.path.join(current_dir, "../../"))
    skill_dir = os.path.join(skills_root, skill_name)
    skill_md_path = os.path.join(skill_dir, "SKILL.md")
    scripts_dir = os.path.join(skill_dir, "scripts")
    
    # Check if skill exists
    if not os.path.exists(skill_dir):
        print(f"Error: Skill '{skill_name}' not found at {skill_dir}")
        sys.exit(1)
        
    # Ensure scripts dir exists
    if not os.path.exists(scripts_dir):
        os.makedirs(scripts_dir)
        
    # Determine script filename based on content
    script_ext = ".sh"
    if code.strip().startswith("#!/usr/bin/env python") or code.strip().startswith("import "):
        script_ext = ".py"
    elif code.strip().startswith("#!/usr/bin/env node") or code.strip().startswith("const "):
        script_ext = ".js"
        
    script_filename = f"{action_name}{script_ext}"
    script_path = os.path.join(scripts_dir, script_filename)
    
    # Write script file
    try:
        with open(script_path, "w") as f:
            f.write(code)
        os.chmod(script_path, 0o755)
        print(f"Created script: {script_path}")
    except Exception as e:
        print(f"Error writing script file: {e}")
        sys.exit(1)
        
    # Update SKILL.md
    try:
        with open(skill_md_path, "r") as f:
            content = f.read()
            
        if f"### {action_name.replace('_', ' ').title()}" in content:
            print(f"Warning: Action '{action_name}' seems to already exist in SKILL.md. Skipping markdown update.")
        else:
            # Prepare new action block
            new_action_block = f"""
### {action_name.replace('_', ' ').title()}
{description}
```bash
{{baseDir}}/scripts/{script_filename}
```
"""
            # Append to content
            # Look for "## Actions"
            if "## Actions" in content:
                # Append at the end of file
                with open(skill_md_path, "a") as f:
                    f.write(new_action_block)
            else:
                # Append "## Actions" and then the block
                with open(skill_md_path, "a") as f:
                    f.write("\n## Actions\n" + new_action_block)
                    
            print(f"Updated SKILL.md for {skill_name}")
            
    except Exception as e:
        print(f"Error updating SKILL.md: {e}")
        # Not exiting here as script file was created
        
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Implement an action for an OpenClaw skill")
    parser.add_argument("--skill", required=True, help="Name of the existing skill")
    parser.add_argument("--action", required=True, help="Name of the action (e.g., 'calculate_pi')")
    parser.add_argument("--description", required=True, help="Description of what the action does")
    parser.add_argument("--code", required=True, help="Hashbang script content")
    
    args = parser.parse_args()
    implement_action(args.skill, args.action, args.description, args.code)
