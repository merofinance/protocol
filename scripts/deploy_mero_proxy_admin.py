from brownie import MeroProxyAdmin

from support.utils import (
    get_deployer,
    as_singleton,
    make_tx_params,
    with_gas_usage,
)


@with_gas_usage
@as_singleton(MeroProxyAdmin)
def main():
    deployer = get_deployer()
    meroProxyAdmin = deployer.deploy(
        MeroProxyAdmin, **make_tx_params()  # type: ignore
    )
    return meroProxyAdmin
