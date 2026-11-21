extends GSGameNetLink

## This game's link: the shared skeleton in [GSGameNetLink], plus the names that are its own.

const PhNetLink := preload("ph_net_link.gd")

const CHANNEL := "ph.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"PropHunt"


func _init() -> void:
	channel = CHANNEL


static func attached_to(parent: Node, p_bridge: Node, server: bool) -> PhNetLink:
	var link := PhNetLink.new()
	link.name = NODE_NAME
	link.bridge = p_bridge
	link.is_server = server
	return link
