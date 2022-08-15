from brownie import SwapperRouter, AddressProvider
from support.constants import AddressProviderKeys
from support.mainnet_contracts import TokenAddresses, VendorAddresses  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@as_singleton(SwapperRouter)
@with_deployed(AddressProvider)
def main(address_provider):
    deployer = get_deployer()
    swapper_router = deployer.deploy(
        SwapperRouter, address_provider, **make_tx_params()  # type: ignore
    )

    address_provider.initializeAddress(
        AddressProviderKeys.SWAPPER_ROUTER.value,
        swapper_router,
        {"from": deployer, **make_tx_params()},
    )

    swapper_router.setCurvePool(
        TokenAddresses.CRV,
        VendorAddresses.CURVE_CRV_ETH_POOL,
        {"from": deployer, **make_tx_params()}
    )

    swapper_router.setCurvePool(
        TokenAddresses.CVX,
        VendorAddresses.CURVE_CVX_ETH_POOL,
        {"from": deployer, **make_tx_params()}
    )
