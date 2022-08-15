from brownie import AddressProvider, MeroUpgradeableProxy, MeroProxyAdmin  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_gas_usage,
    with_deployed,
)


@with_gas_usage
@as_singleton(AddressProvider)
@with_deployed(MeroProxyAdmin)
def main(mero_proxy_admin):
    deployer = get_deployer()
    address_provider = deployer.deploy(AddressProvider, **make_tx_params())
    AddressProvider.remove(address_provider)
    address_provider_proxy = deployer.deploy(
        MeroUpgradeableProxy,
        address_provider,
        mero_proxy_admin,
        b"",
        **make_tx_params()
    )
    MeroUpgradeableProxy.remove(address_provider_proxy)
    AddressProvider.at(address_provider_proxy.address)
