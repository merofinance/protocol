from brownie import interface, MeroEthCvx, AddressProvider, ZERO_ADDRESS
from support.mainnet_contracts import VendorAddresses  # type: ignore

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@as_singleton(MeroEthCvx)
@with_deployed(AddressProvider)
def deploy_eth_cvx_strategy(address_provider):
    tx_params = make_tx_params()
    deployer = get_deployer()

    ## Getting vault
    pools = interface.IAddressProvider(address_provider).allPools()
    vault = None
    for cur_pool in pools:
        pool = interface.ILiquidityPool(cur_pool)
        underlying = pool.getUnderlying()
        if underlying == ZERO_ADDRESS:
            vault = interface.IVault(pool.vault())
            break
    if vault is None:
        raise ValueError("Vault not found.")

    ## Deploying strategy
    strategy = deployer.deploy(
        MeroEthCvx,
        vault,
        deployer,
        49,
        VendorAddresses.CURVE_ALETH_ETH_POOL,
        0,
        address_provider,
        **tx_params
    )

    ## Adding strategy to vault
    vault.initializeStrategy(strategy, {"from": deployer, **tx_params})

    return strategy


def main():
    deploy_eth_cvx_strategy()
