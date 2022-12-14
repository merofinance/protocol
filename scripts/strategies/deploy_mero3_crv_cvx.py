from brownie import Mero3CrvCvx  # type: ignore
from support.utils import (
    as_singleton,
    get_deployer,
    get_strategy_vault,
    make_tx_params,
    with_gas_usage,
)


@as_singleton(Mero3CrvCvx)
@with_gas_usage
def main():
    deployer = get_deployer()
    deployer.deploy(
        Mero3CrvCvx, deployer, get_strategy_vault(), **make_tx_params()  # type: ignore
    )
