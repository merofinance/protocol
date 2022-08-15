import brownie

from brownie import ZERO_ADDRESS
from support.contract_utils import update_topup_handler
from support.convert import format_to_bytes

protocol = {
    "name": "Compound",
    "handler": "0xE2D06cFf756B6bEE58269B40a67E147ba6D6E538",
}


def test_update_handler(admin, alice, topUpAction):
    assert len(topUpAction.getSupportedProtocols()) == 0
    nameB32 = format_to_bytes(protocol["name"], 32, output_hex=True)

    with brownie.reverts("unauthorized access"):
        topUpAction.updateTopUpHandler(nameB32, protocol["handler"], {"from": alice})

    assert nameB32 not in topUpAction.getSupportedProtocols()
    topUpAction.updateTopUpHandler(nameB32, protocol["handler"], {"from": admin})

    assert nameB32 in topUpAction.getSupportedProtocols()
    assert len(topUpAction.getSupportedProtocols()) == 1

    update_topup_handler(topUpAction, nameB32, ZERO_ADDRESS, admin)
    assert nameB32 not in topUpAction.getSupportedProtocols()
