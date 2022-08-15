from brownie.test.managers.runner import RevertContextManager as reverts


def add_action(address_provider, topUpAction, admin):
    assert not address_provider.isAction(topUpAction)
    assert len(address_provider.allActions()) == 0

    address_provider.addAction(topUpAction, {"from": admin})
    assert address_provider.isAction(topUpAction)
    assert len(address_provider.allActions()) == 1

    address_provider.addAction(topUpAction, {"from": admin})
    assert len(address_provider.allActions()) == 1
    assert len(address_provider.allActiveActions()) == 1
    assert not topUpAction.isShutdown()


def test_add_action(address_provider, topUpAction, admin):
    add_action(address_provider, topUpAction, admin)


def test_shutdown_action(controller, address_provider, topUpAction, alice, admin):
    add_action(address_provider, topUpAction, admin)

    with reverts("unauthorized access"):
        controller.shutdownAction(topUpAction, {"from": alice})

    tx = controller.shutdownAction(topUpAction, {"from": admin})
    assert tx.events["ActionShutdown"]["action"] == topUpAction
    assert len(address_provider.allActions()) == 1
    assert len(address_provider.allActiveActions()) == 0
    assert topUpAction.isShutdown()
