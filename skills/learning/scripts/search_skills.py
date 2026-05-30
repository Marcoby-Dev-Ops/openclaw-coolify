#!/usr/bin/env python3
import argparse
import subprocess
import sys
import json

def search_skills(query):
    try:
        # Run clawhub search
        # We use check=True to raise an exception on failure
        result = subprocess.run(
            ["clawhub", "search", query], 
            capture_output=True, 
            text=True, 
            check=True
        )
        
        output = result.stdout.strip()
        if not output:
            print("No skills found matching your query.")
        else:
            print(output)
            
    except subprocess.CalledProcessError as e:
        print(f"Error searching skills: {e}")
        if e.stderr:
            print(f"Details: {e.stderr}")
        sys.exit(1)
    except FileNotFoundError:
        print("Error: 'clawhub' CLI not found. Is it installed in the OpenClaw container?")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Search for OpenClaw skills")
    parser.add_argument("--query", required=True, help="Search query")
    
    args = parser.parse_args()
    search_skills(args.query)
