from brownie import Minter, MeroToken  # type: ignore

from support.utils import (
    get_deployer,
    make_tx_params,
    with_deployed,
    with_gas_usage,
)


@with_gas_usage
@with_deployed(Minter)
def main(minter):
    deployer = get_deployer()
    token = deployer.deploy(MeroToken, "MERO", "MERO", minter, **make_tx_params())  # type: ignore
    minter.setToken(token, {"from": deployer, **make_tx_params()})
