import argparse
import json
from os import path

import eth_abi

parser = argparse.ArgumentParser("parse-governance-call")
parser.add_argument("data")

ROOT_DIR = path.dirname(path.dirname(__file__))
SIGNATURES_PATH = path.join(ROOT_DIR, "build", "4byte_signatures_with_contract.json")

if not path.exists(SIGNATURES_PATH):
    from generate_4byte_json import run_generation

    run_generation(SIGNATURES_PATH, include_contract_name=True)

with open(SIGNATURES_PATH) as f:
    signatures = json.load(f)


def get_types_from_signature(signature):
    is_reading = False
    tuple_depth = 0
    current_type = ""
    result = []
    for char in signature:
        if char == "(":
            if not is_reading:
                is_reading = True
            else:
                tuple_depth += 1
                if current_type:
                    result.append(current_type)
                current_type = "("
        elif char == ")":
            if tuple_depth > 0:
                tuple_depth -= 1
                current_type += ")"
            else:
                is_reading = False
            if current_type:
                result.append(current_type)
                current_type = ""
        elif char == ",":
            if tuple_depth > 0:
                current_type += char
            else:
                result.append(current_type)
                current_type = ""
        elif is_reading:
            current_type += char
    return result


args = parser.parse_args()
governance_data = args.data
if governance_data.startswith("0x"):
    governance_data = governance_data[2:]
governance_data = bytes.fromhex(governance_data)
selector, governance_calldata = governance_data[:4], governance_data[4:]


def parse_data(data):
    call_selector, call_data = data[:4], data[4:]
    call_function = signatures[call_selector.hex()]
    arguments = eth_abi.decode_abi(get_types_from_signature(call_function), call_data)
    return call_function, arguments


call_signature = signatures[selector.hex()]

if call_signature.startswith("GovernanceTimelock.prepareCall"):
    target_address, data, validate_call = eth_abi.decode_abi(
        ["address", "bytes", "bool"], governance_calldata
    )
    call_function, arguments = parse_data(data)
    print(
        f"""prepareCall(
    target_address={target_address},
    target_function={call_function}({arguments}),
    validate={validate_call}
)"""
    )
elif call_signature.startswith("GovernanceTimelock.cancelCall"):
    call_id = eth_abi.decode_abi(["uint64"], governance_calldata)[0]
    print(f"cancelCall({call_id})")
elif call_signature.startswith("GovernanceTimelock.quickExecuteCall"):
    target_address, data = eth_abi.decode_abi(["address", "bytes"], governance_calldata)
    call_function, arguments = parse_data(data)
    print(
        f"""quickExecuteCall(
    target_address={target_address},
    target_function={call_function}({arguments}),
)"""
    )
    call_function, arguments = parse_data(data)
elif call_signature.startswith("GovernanceTimelock.setDelay"):
    target_address, selector, delay = eth_abi.decode_abi(
        ["address", "bytes4", "uint64"], governance_calldata
    )
    signature = signatures[selector.hex()]
    function_name = signature[: signature.index("(")]
    print(
        f"setDelay(target_address={target_address}, function={function_name}, delay={delay})"
    )
