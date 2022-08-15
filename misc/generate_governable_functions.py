import glob
import json
from os import path

import argparse


ROOT_DIR = path.dirname(path.dirname(__file__))
CONFIG_PATH = path.join(ROOT_DIR, "config")
BUILD_PATH = path.join(ROOT_DIR, "build")
CONTRACTS_PATH = path.join(BUILD_PATH, "contracts")
DEFAULT_OUTPUT = path.join(CONFIG_PATH, "governable_functions.json")

ONLY_ROLE_MODIFIERS = ("onlyRole", "onlyRoles2", "onlyRoles3")

parser = argparse.ArgumentParser(prog="generate_governable_functions")
parser.add_argument("--output", "-o", type=str, default=DEFAULT_OUTPUT)

with open(path.join(BUILD_PATH, "4byte_signatures.json")) as f:
    SELECTOR_TO_NAME = json.load(f)


def is_governable_modifier(modifier):
    modifier_name = modifier["modifierName"]["name"]
    return modifier_name == "onlyGovernance" or (
        modifier_name in ONLY_ROLE_MODIFIERS
        and any(
            arg["memberName"] == "GOVERNANCE" for arg in modifier.get("arguments", [])
        )
    )


def is_governable(function_node):
    return any(is_governable_modifier(m) for m in function_node["modifiers"])


def find_functions(node, current_contract=""):
    node_type = node.get("nodeType")

    if node_type == "FunctionDefinition":
        return [(node, current_contract)]

    if node_type == "ContractDefinition":
        current_contract = node["name"]

    functions = []
    for child in node.get("nodes", []):
        functions.extend(find_functions(child, current_contract))

    return functions


def generate_function_config(function):
    node, contract_name = function
    selector = node["functionSelector"]
    function_signature = SELECTOR_TO_NAME[selector]
    return {
        "contract": contract_name,
        "name": node["name"],
        "signature": function_signature,
        "selector": selector,
        "delay": 0,
        "reviewed": False,
    }


def collect_governable_functions(build_path):
    with open(build_path) as f:
        build = json.load(f)
    functions = find_functions(build["ast"])
    return [generate_function_config(f) for f in functions if is_governable(f[0])]


def collect_all_governable_functions(files):
    result = []
    for filepath in files:
        result.extend(collect_governable_functions(filepath))
    return result


def function_id(function):
    return (function["contract"], function["selector"])


def merge_results(existing, current):
    existing_set = {function_id(f) for f in existing}
    new_functions = [f for f in current if function_id(f) not in existing_set]
    return existing + new_functions


def generate_governable_functions(files, output_path):
    governable_functions = collect_all_governable_functions(files)
    if path.exists(output_path):
        with open(output_path, "r") as f:
            existing = json.load(f)
        governable_functions = merge_results(existing, governable_functions)
    return sorted(governable_functions, key=function_id)


def main():
    args = parser.parse_args()
    files = glob.glob(path.join(CONTRACTS_PATH, "**", "*.json"), recursive=True)
    governable_functions = generate_governable_functions(files, args.output)
    with open(args.output, "w") as f:
        json.dump(governable_functions, f, indent=2)


if __name__ == "__main__":
    main()
