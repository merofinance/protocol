from brownie import GovernanceTimelock, RoleManager  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)

@with_gas_usage
@as_singleton(GovernanceTimelock)
@with_deployed(RoleManager)
def main(role_manager):
    # Deploying governance timelock
    deployer = get_deployer()
    governance_timelock = deployer.deploy(GovernanceTimelock, **make_tx_params())

    # Transferring ownership
    role_manager.addGovernor(governance_timelock, {"from": deployer, **make_tx_params()})
    role_manager.renounceGovernance({"from": deployer, **make_tx_params()})

    return governance_timelock
