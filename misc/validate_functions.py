import sys
import json

FUNCTIONS_PATH = "./config/governable_functions.json"


def main():
    with open(FUNCTIONS_PATH, "r") as f:
        functions = json.load(f)
        if any(not function["reviewed"] for function in functions):
            print("Some functions are not reviewed")
            sys.exit(1)
    print("All functions are reviewed")
    sys.exit(0)

main()
