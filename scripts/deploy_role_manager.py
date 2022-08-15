from brownie import RoleManager, AddressProvider, MeroProxyAdmin, MeroRoleManagerUpgradeableProxy  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    get_treasury,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@as_singleton(RoleManager)
@with_deployed(AddressProvider)
@with_deployed(MeroProxyAdmin)
def main(mero_proxy_admin, address_provider):
    deployer = get_deployer()
    treasury = get_treasury()
    role_manager = deployer.deploy(RoleManager, address_provider, **make_tx_params())
    RoleManager.remove(role_manager)
    role_manager_proxy = deployer.deploy(
        MeroRoleManagerUpgradeableProxy,
        role_manager,
        mero_proxy_admin,
        role_manager.initialize.encode_input(),
        **make_tx_params()
    )
    mero_proxy_admin.initializeRoleManager(
        role_manager_proxy, {"from": deployer, **make_tx_params()}
    )
    MeroRoleManagerUpgradeableProxy.remove(role_manager_proxy)
    role_manager = RoleManager.at(role_manager_proxy)
    address_provider.initialize(
        role_manager, treasury, {"from": deployer, **make_tx_params()}
    )
