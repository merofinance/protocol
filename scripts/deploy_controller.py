from brownie import Controller, AddressProvider, MeroUpgradeableProxy, MeroProxyAdmin  # type: ignore
from support.constants import AddressProviderKeys  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@with_deployed(AddressProvider)
def implementation(address_provider):
    deployer = get_deployer()
    controller = deployer.deploy(
        Controller, address_provider, **make_tx_params()  # type: ignore
    )
    Controller.remove(controller)


@with_gas_usage
@as_singleton(Controller)
@with_deployed(AddressProvider)
@with_deployed(MeroProxyAdmin)
def main(mero_proxy_admin, address_provider):
    deployer = get_deployer()
    controller = deployer.deploy(
        Controller, address_provider, **make_tx_params()  # type: ignore
    )
    Controller.remove(controller)

    controller_proxy = deployer.deploy(
        MeroUpgradeableProxy, controller, mero_proxy_admin, b"", **make_tx_params()
    )
    MeroUpgradeableProxy.remove(controller_proxy)
    controller = Controller.at(controller_proxy.address)

    address_provider.initializeAddress(
        AddressProviderKeys.CONTROLLER.value,
        controller.address,
        {"from": deployer, **make_tx_params()},
    )
