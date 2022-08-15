from brownie.test.managers.runner import RevertContextManager as reverts


def test_paused_state(mockAction):
    assert not mockAction.isPaused()
    mockAction.failWhenPaused()
    mockAction.pause()
    assert mockAction.isPaused()
    with reverts("Action is paused"):
        mockAction.failWhenPaused()
    mockAction.unpause()
    assert not mockAction.isPaused()
    mockAction.failWhenPaused()


def test_shutdown_state(mockAction, controller, address_provider, admin):
    address_provider.addAction(mockAction, {"from": admin})
    mockAction.failWhenShutdown()
    assert not mockAction.isShutdown()
    controller.shutdownAction(mockAction, {"from": admin})
    assert mockAction.isShutdown()
    with reverts("Action is shutdown"):
        mockAction.failWhenShutdown()
