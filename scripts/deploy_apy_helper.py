from brownie import ApyHelper, AddressProvider

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@as_singleton(ApyHelper)
@with_deployed(AddressProvider)
def main(address_provider):
    return get_deployer().deploy(ApyHelper, address_provider, **make_tx_params())
