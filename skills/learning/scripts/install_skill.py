#!/usr/bin/env python3
import argparse
import subprocess
import sys

def install_skill(slug):
    try:
        # Run clawhub install
        print(f"Installing skill: {slug}...")
        result = subprocess.run(
            ["clawhub", "install", slug], 
            capture_output=True, 
            text=True, 
            check=True
        )
        
        print(f"Skill '{slug}' installed successfully.")
        if result.stdout:
            print(result.stdout)
            
    except subprocess.CalledProcessError as e:
        print(f"Error installing skill: {e}")
        if e.stderr:
            print(f"Details: {e.stderr}")
        sys.exit(1)
    except FileNotFoundError:
        print("Error: 'clawhub' CLI not found. Is it installed in the OpenClaw container?")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Install an OpenClaw skill")
    parser.add_argument("--slug", required=True, help="Skill slug or URL")
    
    args = parser.parse_args()
    install_skill(args.slug)
