from brownie import AddressProvider, InflationManager, Minter, MeroUpgradeableProxy, MeroProxyAdmin  # type: ignore

from support.utils import get_deployer, make_tx_params, with_deployed, with_gas_usage


@with_gas_usage
@with_deployed(AddressProvider)
@with_deployed(Minter)
@with_deployed(MeroProxyAdmin)
def main(mero_proxy_admin, minter, address_provider):
    deployer = get_deployer()
    inflation_manager = deployer.deploy(
        InflationManager, address_provider, **make_tx_params()  # type: ignore
    )
    InflationManager.remove(inflation_manager)

    inflation_manager_proxy = deployer.deploy(
        MeroUpgradeableProxy,
        inflation_manager,
        mero_proxy_admin,
        b"",
        **make_tx_params()
    )

    MeroUpgradeableProxy.remove(inflation_manager_proxy)
    inflation_manager = InflationManager.at(inflation_manager_proxy.address)

    inflation_manager.setMinter(minter, {"from": deployer, **make_tx_params()})
    address_provider.initializeInflationManager(
        inflation_manager, {"from": deployer, **make_tx_params()}
    )
