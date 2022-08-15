from glob import glob
import brownie
from brownie import interface, GovernanceTimelock, AddressProvider  # type: ignore
import json
import os


FUNCTIONS_PATH = "./config/governable_functions.json"
CONTRACTS_PATH = "./build/contracts/"


from support.utils import (
    get_deployer,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)

def is_abstract(contract):
    with open(CONTRACTS_PATH + contract + ".json") as f:
        build = json.load(f)
        contracts = [
            n
            for n in build["ast"]["nodes"]
            if n["nodeType"] == "ContractDefinition" and n["name"] == contract
        ]
        return contracts[0]["abstract"]


def is_inheriting(contract_file, base):
    with open(contract_file) as f:
        contract_name = os.path.basename(contract_file).replace(".json", "")
        build = json.load(f)
        contract_nodes = [
            n
            for n in build["ast"].get("nodes", [])
            if n["nodeType"] == "ContractDefinition" and n["name"] == contract_name
        ]
        if not contract_nodes:
            return False
        contract_node = contract_nodes[0]
        return any(
            c["baseName"]["name"] == base and c["nodeType"] == "InheritanceSpecifier"
            for c in contract_node["baseContracts"]
        )


class DelayUpdater:
    def __init__(self, governance_timelock, deployer, address_provider):
        self.governance_timelock = governance_timelock
        self.deployer = deployer
        self.address_provider = address_provider

    def update_delay(
        self,
        contract_address,
        contract,
        selector,
        delay,
        signature,
    ):
        existing_delay = self.governance_timelock.delays(contract_address, selector)
        if existing_delay == int(delay):
            return

        if existing_delay == 0:
            print(f"=== SETTING DELAY OF {int(delay)} FOR {contract}.{signature} ===")
            self.governance_timelock.setDelay(
                contract_address,
                selector,
                int(delay),
                {"from": self.deployer, **make_tx_params()},
            )
        else:
            print(
                f"=== PREPARING UPDATE DELAY OF {int(delay)} FOR {contract}.{signature} ==="
            )
            data = self.governance_timelock.updateDelay.encode_input(
                contract_address, selector, int(delay)
            )
            self.governance_timelock.prepareCall(
                self.governance_timelock,
                data,
                True,
                {"from": self.deployer, **make_tx_params()},
            )

    def set_liquidity_pools_delay(self, selector, delay, signature):
        pools = self.address_provider.allPools()
        for pool in pools:
            pool_contract = interface.ILiquidityPool(pool)
            self.update_delay(
                pool,
                pool_contract.name(),
                selector,
                delay,
                signature,
            )

    def set_staker_vaults_delay(self, selector, delay, signature):
        vaults = self.address_provider.allStakerVaults()
        for vault in vaults:
            lp_token = interface.IStakerVault(vault).getToken()
            lp_token_name = interface.IERC20Full(lp_token).name()
            name = f"StakerVault@{lp_token_name}"
            self.update_delay(vault, name, selector, delay, signature)

    def set_lp_tokens_delay(self, selector, delay, signature):
        pools = self.address_provider.allPools()
        for pool in pools:
            lp_token = interface.ILiquidityPool(pool).lpToken()
            name = interface.IERC20Full(lp_token).name()
            self.update_delay(lp_token, name, selector, delay, signature)

    def set_vaults_delay(self, selector, delay, signature):
        pools = self.address_provider.allPools()
        for pool in pools:
            vault = interface.ILiquidityPool(pool).vault()
            name = f"Vault@{interface.ILiquidityPool(pool).name()}"
            self.update_delay(vault, name, selector, delay, signature)

    def set_abstract_contract_delay(self, contract, selector, delay, signature):
        for filename in glob(os.path.join(CONTRACTS_PATH, "*.json")):
            if not is_inheriting(filename, contract):
                continue

            self.set_delay(
                os.path.basename(filename).replace(".json", ""),
                selector,
                delay,
                signature,
            )

    def set_delay(self, contract, selector, delay, signature):
        if contract == "LiquidityPool":
            self.set_liquidity_pools_delay(selector, delay, signature)
        elif contract == "StakerVault":
            self.set_staker_vaults_delay(selector, delay, signature)
        elif contract == "LpToken":
            self.set_lp_tokens_delay(selector, delay, signature)
        elif contract == "Vault":
            self.set_vaults_delay(selector, delay, signature)
        elif is_abstract(contract):
            self.set_abstract_contract_delay(contract, selector, delay, signature)
        else:
            # Setting delays for all contract deployments
            for contract_address in getattr(brownie, contract):
                self.update_delay(
                    contract_address,
                    contract,
                    selector,
                    delay,
                    signature,
                )


@with_gas_usage
@with_deployed(AddressProvider)
@with_deployed(GovernanceTimelock)
def main(governance_timelock, address_provider):
    # Validate Functions
    with open(FUNCTIONS_PATH, "r") as f:
        functions = json.load(f)
        if any(not function["reviewed"] for function in functions):
            raise Exception("Not all functions have been reviewed")

    # Executing all ready calls
    deployer = get_deployer()
    ready_calls = governance_timelock.readyCalls()
    for call in ready_calls:
        print("=== EXECUTING CALL {} ===".format(call[0]))
        governance_timelock.executeCall(call[0], {"from": deployer, **make_tx_params()})

    delay_updater = DelayUpdater(governance_timelock, deployer, address_provider)

    # Initializing delays
    with open(FUNCTIONS_PATH, "r") as f:
        for function in json.load(f):
            delay_updater.set_delay(
                function["contract"],
                function["selector"],
                function["delay"] * 86_400,
                function["signature"],
            )
