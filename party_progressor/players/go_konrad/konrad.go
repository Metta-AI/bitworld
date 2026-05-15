package main

import (
	"container/heap"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"math/rand"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	PlayerDefaultPort         = 2000
	ScreenWidth               = 128
	ScreenHeight              = 128
	WorldWidthTiles           = 32
	WorldHeightTiles          = 32
	WorldTileSize             = 32
	WorldWidthPixels          = WorldWidthTiles * WorldTileSize
	WorldHeightPixels         = WorldHeightTiles * WorldTileSize
	PlayerWebSocketPath       = "/player"
	DefaultHost               = "localhost"

	MapSpriteId              = 1
	MapObjectId              = 1
	PlayerSpriteBase         = 100
	SelectedPlayerSpriteBase = 200
	MobSpriteId              = 300
	BossSpriteId             = 301
	CoinSpriteId             = 302
	HeartSpriteId            = 303
	SwooshSpriteBase         = 304
	TrollSpriteId            = 312
	TerrainSpriteBase        = 320
	PlayerHudSpriteId        = 600
	PlayerObjectBase         = 1000
	MobObjectBase            = 2000

	ButtonUp    uint8 = 1 << 0
	ButtonDown  uint8 = 1 << 1
	ButtonLeft  uint8 = 1 << 2
	ButtonRight uint8 = 1 << 3
	ButtonA     uint8 = 1 << 5
	ButtonB     uint8 = 1 << 6

	PlayerSpriteSlots         = 64
	SelectedPlayerSpriteSlots = 64
	SwooshSpriteSlots         = 8
	TerrainSpriteSlots        = 5
	MaxDrainMessages          = 256
	PathCellSize              = 8
	PathGridWidth             = WorldWidthPixels / PathCellSize
	PathGridHeight            = WorldHeightPixels / PathCellSize
	MoveDeadband              = 5
	GoalArrivalRadius         = 18
	AttackReach               = 46
	AttackAlignSlack          = 22
	AttackCooldownTicks       = 7
	ObstaclePad               = 8
	PathLookaheadCells        = 4
	StuckFrameThreshold       = 14
	JiggleDuration            = 12
	SkipTargetTicks           = 72
	ExploreStep               = 17
	MoveMask                  = ButtonUp | ButtonDown | ButtonLeft | ButtonRight
)

var MaxIntValue = int(^uint(0) >> 1)

type SpriteKind int

const (
	SpriteUnknown SpriteKind = iota
	SpriteMap
	SpritePlayer
	SpriteMob
	SpriteTroll
	SpriteBoss
	SpriteCoin
	SpriteHeart
	SpriteSwoosh
	SpriteTerrain
	SpriteHud
	SpriteText
)

type TargetKind int

const (
	TargetExplore TargetKind = iota
	TargetCoin
	TargetHeart
	TargetMob
	TargetTroll
	TargetBoss
)

type SpriteInfo struct {
	defined bool
	width   int
	height  int
	label   string
	kind    SpriteKind
	pixels  []byte
}

type ObjectState struct {
	present  bool
	x        int
	y        int
	z        int
	layer    int
	spriteId int
}

type SpriteBounds struct {
	x int
	y int
	w int
	h int
}

type Target struct {
	found    bool
	kind     TargetKind
	objectId int
	x        int
	y        int
	label    string
}

type PathNode struct {
	priority int
	index    int
}

type PathStep struct {
	found  bool
	nextTx int
	nextTy int
}

type Bot struct {
	sprites               []SpriteInfo
	objects               []ObjectState
	rng                   *rand.Rand
	cameraX               int
	cameraY               int
	playerWorldX          int
	playerWorldY          int
	previousPlayerX       int
	previousPlayerY       int
	havePlayerSample      bool
	selfObjectId          int
	frameTick             int
	exploreIndex          int
	hasExploreGoal        bool
	exploreX              int
	exploreY              int
	stuckFrames           int
	jiggleTicks           int
	jiggleMask            uint8
	attackCooldown        int
	currentTargetId       int
	currentTargetKind     TargetKind
	currentTargetX        int
	currentTargetY        int
	currentTargetDistance int
	currentTargetLabel    string
	skipTargetId          int
	skipTicks             int
	coinCount             int
	heartCount            int
	killCount             int
	intent                string
	lastMask              uint8
	nextChatTick          int
	lastChat              string
}

type PathHeap []PathNode

func (h PathHeap) Len() int {
	return len(h)
}

func (h PathHeap) Less(i, j int) bool {
	if h[i].priority == h[j].priority {
		return h[i].index < h[j].index
	}
	return h[i].priority < h[j].priority
}

func (h PathHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
}

func (h *PathHeap) Push(value any) {
	*h = append(*h, value.(PathNode))
}

func (h *PathHeap) Pop() any {
	old := *h
	item := old[len(old)-1]
	*h = old[:len(old)-1]
	return item
}

func newBot() *Bot {
	seed := time.Now().UnixNano() ^ int64(os.Getpid())
	rng := rand.New(rand.NewSource(seed))
	return &Bot{
		rng:             rng,
		selfObjectId:    -1,
		currentTargetId: -1,
		skipTargetId:    -1,
		exploreIndex:    rng.Intn(PathGridWidth * PathGridHeight),
		nextChatTick:    72,
	}
}

func gridIndex(tx, ty int) int {
	return ty*PathGridWidth + tx
}

func inGrid(tx, ty int) bool {
	return tx >= 0 && ty >= 0 && tx < PathGridWidth && ty < PathGridHeight
}

func distanceSquared(ax, ay, bx, by int) int {
	dx := ax - bx
	dy := ay - by
	return dx*dx + dy*dy
}

func manhattan(ax, ay, bx, by int) int {
	return abs(ax-bx) + abs(ay-by)
}

func tileCenterX(tx int) int {
	return tx*PathCellSize + PathCellSize/2
}

func tileCenterY(ty int) int {
	return ty*PathCellSize + PathCellSize/2
}

func clamp(value, low, high int) int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func clampTileX(x int) int {
	return clamp(x/PathCellSize, 0, PathGridWidth-1)
}

func clampTileY(y int) int {
	return clamp(y/PathCellSize, 0, PathGridHeight-1)
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func classifySprite(spriteId int, label string) SpriteKind {
	lower := strings.ToLower(label)
	if spriteId == MapSpriteId || lower == "map" {
		return SpriteMap
	}
	if spriteId >= PlayerSpriteBase && spriteId < PlayerSpriteBase+PlayerSpriteSlots {
		return SpritePlayer
	}
	if spriteId >= SelectedPlayerSpriteBase &&
		spriteId < SelectedPlayerSpriteBase+SelectedPlayerSpriteSlots {
		return SpritePlayer
	}
	if spriteId == MobSpriteId || lower == "ghost" {
		return SpriteMob
	}
	if spriteId == TrollSpriteId || lower == "troll" {
		return SpriteTroll
	}
	if spriteId == BossSpriteId || lower == "pigman" {
		return SpriteBoss
	}
	if spriteId == CoinSpriteId || lower == "coin" {
		return SpriteCoin
	}
	if spriteId == HeartSpriteId || lower == "heart" {
		return SpriteHeart
	}
	if spriteId >= SwooshSpriteBase && spriteId < SwooshSpriteBase+SwooshSpriteSlots {
		return SpriteSwoosh
	}
	if spriteId >= TerrainSpriteBase && spriteId < TerrainSpriteBase+TerrainSpriteSlots {
		return SpriteTerrain
	}
	if spriteId == PlayerHudSpriteId {
		return SpriteHud
	}
	if len(label) > 0 {
		return SpriteText
	}
	return SpriteUnknown
}

func targetKindForSprite(kind SpriteKind) TargetKind {
	switch kind {
	case SpriteTroll:
		return TargetTroll
	case SpriteBoss:
		return TargetBoss
	default:
		return TargetMob
	}
}

func targetLabel(kind TargetKind) string {
	switch kind {
	case TargetExplore:
		return "explore"
	case TargetCoin:
		return "coin"
	case TargetHeart:
		return "heart"
	case TargetMob:
		return "hunt"
	case TargetTroll:
		return "fight"
	case TargetBoss:
		return "boss"
	default:
		return ""
	}
}

func (bot *Bot) ensureSprite(spriteId int) {
	for spriteId >= len(bot.sprites) {
		bot.sprites = append(bot.sprites, SpriteInfo{})
	}
}

func (bot *Bot) ensureObject(objectId int) {
	for objectId >= len(bot.objects) {
		bot.objects = append(bot.objects, ObjectState{})
	}
}

func (bot *Bot) spriteInfo(spriteId int) SpriteInfo {
	if spriteId >= 0 && spriteId < len(bot.sprites) {
		return bot.sprites[spriteId]
	}
	return SpriteInfo{}
}

func readU16(blob []byte, offset int) int {
	return int(binary.LittleEndian.Uint16(blob[offset : offset+2]))
}

func readI16(blob []byte, offset int) int {
	return int(int16(binary.LittleEndian.Uint16(blob[offset : offset+2])))
}

func readU32(blob []byte, offset int) int {
	return int(binary.LittleEndian.Uint32(blob[offset : offset+4]))
}

func snappyDecompress(data []byte) ([]byte, error) {
	index := 0
	expected := 0
	shift := 0
	for {
		if index >= len(data) {
			return nil, errors.New("truncated snappy length")
		}
		value := data[index]
		index++
		expected |= int(value&0x7f) << shift
		if value < 128 {
			break
		}
		shift += 7
	}
	output := make([]byte, 0, expected)
	for index < len(data) {
		tag := data[index]
		index++
		tagType := tag & 0x03
		if tagType == 0 {
			lengthCode := int(tag >> 2)
			length := 0
			if lengthCode < 60 {
				length = lengthCode + 1
			} else {
				extra := lengthCode - 59
				if index+extra > len(data) {
					return nil, errors.New("truncated snappy literal length")
				}
				length = 1
				for i := 0; i < extra; i++ {
					length += int(data[index+i]) << (8 * i)
				}
				index += extra
			}
			if index+length > len(data) {
				return nil, errors.New("truncated snappy literal")
			}
			output = append(output, data[index:index+length]...)
			index += length
			continue
		}

		length := 0
		offset := 0
		switch tagType {
		case 1:
			if index >= len(data) {
				return nil, errors.New("truncated snappy copy1")
			}
			length = int((tag>>2)&0x07) + 4
			offset = int((tag&0xe0)<<3) | int(data[index])
			index++
		case 2:
			if index+2 > len(data) {
				return nil, errors.New("truncated snappy copy2")
			}
			length = int(tag>>2) + 1
			offset = readU16(data, index)
			index += 2
		default:
			if index+4 > len(data) {
				return nil, errors.New("truncated snappy copy4")
			}
			length = int(tag>>2) + 1
			offset = readU32(data, index)
			index += 4
		}
		if offset <= 0 || offset > len(output) {
			return nil, errors.New("invalid snappy copy offset")
		}
		for i := 0; i < length; i++ {
			output = append(output, output[len(output)-offset])
		}
	}
	if len(output) != expected {
		return nil, fmt.Errorf(
			"snappy length mismatch: expected %d, got %d",
			expected,
			len(output),
		)
	}
	return output, nil
}

func (bot *Bot) applySpritePacket(packet []byte) bool {
	offset := 0
	for offset < len(packet) {
		messageType := packet[offset]
		offset++
		switch messageType {
		case 0x01:
			if offset+10 > len(packet) {
				return false
			}
			spriteId := readU16(packet, offset)
			width := readU16(packet, offset+2)
			height := readU16(packet, offset+4)
			compressedLen := readU32(packet, offset+6)
			offset += 10
			if offset+compressedLen+2 > len(packet) {
				return false
			}
			compressed := packet[offset : offset+compressedLen]
			offset += compressedLen
			labelLen := readU16(packet, offset)
			offset += 2
			if offset+labelLen > len(packet) {
				return false
			}
			label := string(packet[offset : offset+labelLen])
			offset += labelLen
			pixels := []byte{}
			if compressedLen > 0 {
				raw, err := snappyDecompress(compressed)
				if err != nil {
					return false
				}
				pixels = raw
			}
			if len(pixels) != width*height*4 {
				pixels = []byte{}
			}
			bot.ensureSprite(spriteId)
			bot.sprites[spriteId] = SpriteInfo{
				defined: true,
				width:   width,
				height:  height,
				label:   label,
				kind:    classifySprite(spriteId, label),
				pixels:  pixels,
			}
		case 0x02:
			if offset+11 > len(packet) {
				return false
			}
			objectId := readU16(packet, offset)
			x := readI16(packet, offset+2)
			y := readI16(packet, offset+4)
			z := readI16(packet, offset+6)
			layer := int(packet[offset+8])
			spriteId := readU16(packet, offset+9)
			offset += 11
			bot.ensureObject(objectId)
			bot.objects[objectId] = ObjectState{
				present:  true,
				x:        x,
				y:        y,
				z:        z,
				layer:    layer,
				spriteId: spriteId,
			}
		case 0x03:
			if offset+2 > len(packet) {
				return false
			}
			objectId := readU16(packet, offset)
			offset += 2
			if objectId >= 0 && objectId < len(bot.objects) {
				bot.objects[objectId].present = false
			}
		case 0x04:
			for i := range bot.objects {
				bot.objects[i].present = false
			}
		case 0x05:
			if offset+5 > len(packet) {
				return false
			}
			offset += 5
		case 0x06:
			if offset+3 > len(packet) {
				return false
			}
			offset += 3
		default:
			return false
		}
	}
	return true
}

func (bot *Bot) updateCamera() {
	if MapObjectId < len(bot.objects) && bot.objects[MapObjectId].present {
		bot.cameraX = -bot.objects[MapObjectId].x
		bot.cameraY = -bot.objects[MapObjectId].y
	}
}

func visibleBounds(sprite SpriteInfo) SpriteBounds {
	if sprite.width <= 0 ||
		sprite.height <= 0 ||
		len(sprite.pixels) != sprite.width*sprite.height*4 {
		return SpriteBounds{x: 0, y: 0, w: sprite.width, h: sprite.height}
	}
	minX := sprite.width
	minY := sprite.height
	maxX := -1
	maxY := -1
	for y := 0; y < sprite.height; y++ {
		for x := 0; x < sprite.width; x++ {
			offset := (y*sprite.width+x)*4 + 3
			if sprite.pixels[offset] == 0 {
				continue
			}
			minX = min(minX, x)
			minY = min(minY, y)
			maxX = max(maxX, x)
			maxY = max(maxY, y)
		}
	}
	if maxX < minX || maxY < minY {
		return SpriteBounds{}
	}
	return SpriteBounds{x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1}
}

func lowerCenterBounds(bounds SpriteBounds) SpriteBounds {
	if bounds.w <= 0 || bounds.h <= 0 {
		return bounds
	}
	width := max(6, bounds.w/3)
	height := max(6, bounds.h/4)
	return SpriteBounds{
		x: bounds.x + (bounds.w-width)/2,
		y: bounds.y + bounds.h - height,
		w: width,
		h: height,
	}
}

func terrainBounds(sprite SpriteInfo) SpriteBounds {
	bounds := visibleBounds(sprite)
	lower := strings.ToLower(sprite.label)
	if lower == "terraintree" || lower == "terrainevergreen" {
		return lowerCenterBounds(bounds)
	}
	return bounds
}

func (bot *Bot) updatePlayerPosition() {
	bestDistance := MaxIntValue
	bestX := bot.cameraX + ScreenWidth/2
	bestY := bot.cameraY + ScreenHeight/2
	bestId := -1
	for objectId, state := range bot.objects {
		if !state.present {
			continue
		}
		if objectId < PlayerObjectBase || objectId >= MobObjectBase {
			continue
		}
		sprite := bot.spriteInfo(state.spriteId)
		if sprite.kind != SpritePlayer {
			continue
		}
		screenX := state.x + sprite.width/2
		screenY := state.y + sprite.height/2
		distance := distanceSquared(
			screenX,
			screenY,
			ScreenWidth/2,
			ScreenHeight/2,
		)
		if distance < bestDistance {
			bestDistance = distance
			bestX = bot.cameraX + screenX
			bestY = bot.cameraY + screenY
			bestId = objectId
		}
	}
	bot.playerWorldX = bestX
	bot.playerWorldY = bestY
	bot.selfObjectId = bestId
}

func isBlocked(blocked []bool, tx, ty int) bool {
	if !inGrid(tx, ty) {
		return true
	}
	return blocked[gridIndex(tx, ty)]
}

func markBlocked(blocked []bool, x, y, w, h int) {
	if w <= 0 || h <= 0 {
		return
	}
	minTx := clampTileX(max(0, x-ObstaclePad))
	minTy := clampTileY(max(0, y-ObstaclePad))
	maxTx := clampTileX(min(WorldWidthPixels-1, x+w+ObstaclePad-1))
	maxTy := clampTileY(min(WorldHeightPixels-1, y+h+ObstaclePad-1))
	for ty := minTy; ty <= maxTy; ty++ {
		for tx := minTx; tx <= maxTx; tx++ {
			blocked[gridIndex(tx, ty)] = true
		}
	}
}

func (bot *Bot) targetCenter(state ObjectState, sprite SpriteInfo) (int, int) {
	bounds := visibleBounds(sprite)
	return bot.cameraX + state.x + bounds.x + bounds.w/2,
		bot.cameraY + state.y + bounds.y + bounds.h/2
}

func (bot *Bot) scanWorld() ([]bool, []Target, []Target) {
	blocked := make([]bool, PathGridWidth*PathGridHeight)
	pickups := []Target{}
	mobs := []Target{}
	for objectId, state := range bot.objects {
		if !state.present {
			continue
		}
		sprite := bot.spriteInfo(state.spriteId)
		if !sprite.defined {
			continue
		}
		switch sprite.kind {
		case SpriteTerrain:
			bounds := terrainBounds(sprite)
			markBlocked(
				blocked,
				bot.cameraX+state.x+bounds.x,
				bot.cameraY+state.y+bounds.y,
				bounds.w,
				bounds.h,
			)
		case SpriteCoin:
			x, y := bot.targetCenter(state, sprite)
			pickups = append(pickups, Target{
				found:    true,
				kind:     TargetCoin,
				objectId: objectId,
				x:        x,
				y:        y,
				label:    targetLabel(TargetCoin),
			})
		case SpriteHeart:
			x, y := bot.targetCenter(state, sprite)
			pickups = append(pickups, Target{
				found:    true,
				kind:     TargetHeart,
				objectId: objectId,
				x:        x,
				y:        y,
				label:    targetLabel(TargetHeart),
			})
		case SpriteMob, SpriteTroll, SpriteBoss:
			kind := targetKindForSprite(sprite.kind)
			x, y := bot.targetCenter(state, sprite)
			mobs = append(mobs, Target{
				found:    true,
				kind:     kind,
				objectId: objectId,
				x:        x,
				y:        y,
				label:    targetLabel(kind),
			})
		}
	}
	return blocked, pickups, mobs
}

func nearestOpenTile(blocked []bool, tx, ty int) (bool, int, int) {
	if inGrid(tx, ty) && !isBlocked(blocked, tx, ty) {
		return true, tx, ty
	}
	for radius := 1; radius <= 6; radius++ {
		for dy := -radius; dy <= radius; dy++ {
			for dx := -radius; dx <= radius; dx++ {
				if abs(dx) != radius && abs(dy) != radius {
					continue
				}
				nx := tx + dx
				ny := ty + dy
				if inGrid(nx, ny) && !isBlocked(blocked, nx, ny) {
					return true, nx, ny
				}
			}
		}
	}
	return false, tx, ty
}

func heuristicDistance(ax, ay, bx, by int) int {
	return abs(ax-bx) + abs(ay-by)
}

func reconstructStep(parents []int, startIndex, goalIndex int) PathStep {
	path := []int{goalIndex}
	for path[len(path)-1] != startIndex {
		nextIndex := parents[path[len(path)-1]]
		if nextIndex < 0 || nextIndex == path[len(path)-1] {
			return PathStep{}
		}
		path = append(path, nextIndex)
	}
	stepIndex := path[max(0, len(path)-1-PathLookaheadCells)]
	return PathStep{
		found:  true,
		nextTx: stepIndex % PathGridWidth,
		nextTy: stepIndex / PathGridWidth,
	}
}

func findPathStep(blocked []bool, startX, startY, goalX, goalY int) PathStep {
	startTx := clampTileX(startX)
	startTy := clampTileY(startY)
	openFound, goalTx, goalTy := nearestOpenTile(
		blocked,
		clampTileX(goalX),
		clampTileY(goalY),
	)
	if !openFound {
		return PathStep{}
	}
	startIndex := gridIndex(startTx, startTy)
	goalIndex := gridIndex(goalTx, goalTy)
	area := PathGridWidth * PathGridHeight
	if startTx == goalTx && startTy == goalTy {
		return PathStep{found: true, nextTx: startTx, nextTy: startTy}
	}

	parents := make([]int, area)
	costs := make([]int, area)
	closed := make([]bool, area)
	for i := 0; i < area; i++ {
		parents[i] = -2
		costs[i] = MaxIntValue
	}
	parents[startIndex] = startIndex
	costs[startIndex] = 0
	openSet := &PathHeap{}
	heap.Push(openSet, PathNode{
		priority: heuristicDistance(startTx, startTy, goalTx, goalTy),
		index:    startIndex,
	})

	for openSet.Len() > 0 {
		current := heap.Pop(openSet).(PathNode)
		if closed[current.index] {
			continue
		}
		if current.index == goalIndex {
			return reconstructStep(parents, startIndex, goalIndex)
		}
		closed[current.index] = true
		tx := current.index % PathGridWidth
		ty := current.index / PathGridWidth
		for _, delta := range [][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}} {
			nextTx := tx + delta[0]
			nextTy := ty + delta[1]
			if !inGrid(nextTx, nextTy) {
				continue
			}
			if isBlocked(blocked, nextTx, nextTy) {
				continue
			}
			nextIndex := gridIndex(nextTx, nextTy)
			if closed[nextIndex] {
				continue
			}
			tentative := costs[current.index] + 1
			if tentative >= costs[nextIndex] {
				continue
			}
			costs[nextIndex] = tentative
			parents[nextIndex] = current.index
			heap.Push(openSet, PathNode{
				priority: tentative +
					heuristicDistance(nextTx, nextTy, goalTx, goalTy),
				index: nextIndex,
			})
		}
	}
	return PathStep{}
}

func (bot *Bot) randomMoveMask() uint8 {
	switch bot.rng.Intn(4) {
	case 0:
		return ButtonUp
	case 1:
		return ButtonDown
	case 2:
		return ButtonLeft
	default:
		return ButtonRight
	}
}

func (bot *Bot) updateStuck() {
	if !bot.havePlayerSample {
		bot.previousPlayerX = bot.playerWorldX
		bot.previousPlayerY = bot.playerWorldY
		bot.havePlayerSample = true
		return
	}
	moved := distanceSquared(
		bot.playerWorldX,
		bot.playerWorldY,
		bot.previousPlayerX,
		bot.previousPlayerY,
	)
	if (bot.lastMask&MoveMask) != 0 && moved <= 1 {
		bot.stuckFrames++
	} else {
		bot.stuckFrames = 0
	}
	bot.previousPlayerX = bot.playerWorldX
	bot.previousPlayerY = bot.playerWorldY
	if bot.stuckFrames >= StuckFrameThreshold {
		bot.jiggleTicks = JiggleDuration
		bot.jiggleMask = bot.randomMoveMask()
		if bot.currentTargetId >= 0 {
			bot.skipTargetId = bot.currentTargetId
			bot.skipTicks = SkipTargetTicks
		}
		bot.stuckFrames = 0
		bot.hasExploreGoal = false
	}
}

func (bot *Bot) targetScore(target Target) int {
	distance := manhattan(
		bot.playerWorldX,
		bot.playerWorldY,
		target.x,
		target.y,
	)
	switch target.kind {
	case TargetCoin:
		return distance
	case TargetHeart:
		return distance + 35
	case TargetMob:
		if distance < 90 {
			return distance - 95
		}
		return distance + 130
	case TargetTroll:
		if distance < 105 {
			return distance - 85
		}
		return distance + 155
	case TargetBoss:
		if distance < 120 {
			return distance - 70
		}
		return distance + 220
	default:
		return distance + 400
	}
}

func (bot *Bot) refreshExploreGoal(blocked []bool) {
	if bot.hasExploreGoal &&
		distanceSquared(
			bot.playerWorldX,
			bot.playerWorldY,
			bot.exploreX,
			bot.exploreY,
		) > GoalArrivalRadius*GoalArrivalRadius {
		return
	}
	area := PathGridWidth * PathGridHeight
	for attempt := 0; attempt < area; attempt++ {
		index := (bot.exploreIndex + attempt*ExploreStep) % area
		tx := index % PathGridWidth
		ty := index / PathGridWidth
		if isBlocked(blocked, tx, ty) {
			continue
		}
		bot.exploreIndex = (index + ExploreStep) % area
		bot.exploreX = tileCenterX(tx)
		bot.exploreY = tileCenterY(ty)
		bot.hasExploreGoal = true
		return
	}
	bot.exploreX = WorldWidthPixels / 2
	bot.exploreY = WorldHeightPixels / 2
	bot.hasExploreGoal = true
}

func (bot *Bot) chooseTarget(blocked []bool, pickups, mobs []Target) Target {
	result := Target{}
	bestScore := MaxIntValue
	for _, pickup := range pickups {
		if bot.skipTicks > 0 && pickup.objectId == bot.skipTargetId {
			continue
		}
		score := bot.targetScore(pickup)
		if score < bestScore {
			bestScore = score
			result = pickup
		}
	}
	for _, mob := range mobs {
		if bot.skipTicks > 0 && mob.objectId == bot.skipTargetId {
			continue
		}
		score := bot.targetScore(mob)
		if score < bestScore {
			bestScore = score
			result = mob
		}
	}
	if result.found {
		return result
	}
	bot.refreshExploreGoal(blocked)
	return Target{
		found:    true,
		kind:     TargetExplore,
		objectId: -1,
		x:        bot.exploreX,
		y:        bot.exploreY,
		label:    targetLabel(TargetExplore),
	}
}

func (bot *Bot) nearestMob(mobs []Target) Target {
	result := Target{}
	bestDistance := MaxIntValue
	for _, mob := range mobs {
		distance := distanceSquared(
			bot.playerWorldX,
			bot.playerWorldY,
			mob.x,
			mob.y,
		)
		if distance < bestDistance {
			bestDistance = distance
			result = mob
		}
	}
	return result
}

func containsTarget(targets []Target, objectId int) bool {
	for _, target := range targets {
		if target.objectId == objectId {
			return true
		}
	}
	return false
}

func (bot *Bot) rememberTarget(target Target) {
	bot.currentTargetId = target.objectId
	bot.currentTargetKind = target.kind
	bot.currentTargetX = target.x
	bot.currentTargetY = target.y
	bot.currentTargetLabel = target.label
	bot.currentTargetDistance = manhattan(
		bot.playerWorldX,
		bot.playerWorldY,
		target.x,
		target.y,
	)
}

func (bot *Bot) updateTargetResult(pickups, mobs []Target) {
	if bot.currentTargetId < 0 {
		return
	}
	stillPresent := true
	switch bot.currentTargetKind {
	case TargetCoin, TargetHeart:
		stillPresent = containsTarget(pickups, bot.currentTargetId)
	case TargetMob, TargetTroll, TargetBoss:
		stillPresent = containsTarget(mobs, bot.currentTargetId)
	}
	if stillPresent {
		return
	}
	switch bot.currentTargetKind {
	case TargetCoin:
		if bot.currentTargetDistance < 64 {
			bot.coinCount++
			fmt.Printf(
				"coin collected id=%d total=%d\n",
				bot.currentTargetId,
				bot.coinCount,
			)
		}
	case TargetHeart:
		if bot.currentTargetDistance < 64 {
			bot.heartCount++
			fmt.Printf(
				"heart collected id=%d total=%d\n",
				bot.currentTargetId,
				bot.heartCount,
			)
		}
	case TargetMob, TargetTroll, TargetBoss:
		if bot.currentTargetDistance < 96 {
			bot.killCount++
			fmt.Printf(
				"monster down id=%d total=%d\n",
				bot.currentTargetId,
				bot.killCount,
			)
		}
	}
	bot.currentTargetId = -1
}

func faceMask(dx, dy int) uint8 {
	if abs(dx) > abs(dy) {
		if dx < 0 {
			return ButtonLeft
		}
		return ButtonRight
	}
	if dy < 0 {
		return ButtonUp
	}
	return ButtonDown
}

func (bot *Bot) steerMask(x, y int) uint8 {
	var result uint8
	dx := x - bot.playerWorldX
	dy := y - bot.playerWorldY
	if abs(dx) > MoveDeadband {
		if dx < 0 {
			result |= ButtonLeft
		} else {
			result |= ButtonRight
		}
	}
	if abs(dy) > MoveDeadband {
		if dy < 0 {
			result |= ButtonUp
		} else {
			result |= ButtonDown
		}
	}
	return result
}

func (bot *Bot) canAttack(target Target) bool {
	dx := target.x - bot.playerWorldX
	dy := target.y - bot.playerWorldY
	return (abs(dx) <= AttackReach && abs(dy) <= AttackAlignSlack) ||
		(abs(dy) <= AttackReach && abs(dx) <= AttackAlignSlack)
}

func (bot *Bot) attackMask(target Target) uint8 {
	result := faceMask(target.x-bot.playerWorldX, target.y-bot.playerWorldY)
	if bot.attackCooldown == 0 {
		result |= ButtonA
		bot.attackCooldown = AttackCooldownTicks
	}
	return result
}

func isMonsterTarget(kind TargetKind) bool {
	return kind == TargetMob || kind == TargetTroll || kind == TargetBoss
}

func (bot *Bot) decideNextMask() uint8 {
	bot.updateCamera()
	bot.updatePlayerPosition()
	if bot.attackCooldown > 0 {
		bot.attackCooldown--
	}
	if bot.skipTicks > 0 {
		bot.skipTicks--
		if bot.skipTicks == 0 {
			bot.skipTargetId = -1
		}
	}
	blocked, pickups, mobs := bot.scanWorld()
	bot.updateTargetResult(pickups, mobs)
	bot.updateStuck()
	if bot.jiggleTicks > 0 {
		bot.jiggleTicks--
		bot.intent = "unstuck"
		return bot.jiggleMask
	}
	closeMob := bot.nearestMob(mobs)
	if closeMob.found && bot.canAttack(closeMob) {
		bot.rememberTarget(closeMob)
		bot.intent = closeMob.label
		return bot.attackMask(closeMob)
	}
	target := bot.chooseTarget(blocked, pickups, mobs)
	bot.rememberTarget(target)
	bot.intent = target.label
	if isMonsterTarget(target.kind) && bot.canAttack(target) {
		return bot.attackMask(target)
	}
	step := findPathStep(
		blocked,
		bot.playerWorldX,
		bot.playerWorldY,
		target.x,
		target.y,
	)
	if step.found {
		startTx := clampTileX(bot.playerWorldX)
		startTy := clampTileY(bot.playerWorldY)
		if step.nextTx == startTx && step.nextTy == startTy {
			return bot.steerMask(target.x, target.y)
		}
		return bot.steerMask(tileCenterX(step.nextTx), tileCenterY(step.nextTy))
	}
	if target.objectId >= 0 {
		bot.skipTargetId = target.objectId
		bot.skipTicks = SkipTargetTicks
	}
	bot.hasExploreGoal = false
	return bot.steerMask(target.x, target.y)
}

func playerInputBlob(mask uint8) []byte {
	return []byte{0x84, mask & 0x7f}
}

func chatBlob(text string) []byte {
	payload := []byte(text)
	packet := make([]byte, 3+len(payload))
	packet[0] = 0x81
	binary.LittleEndian.PutUint16(packet[1:3], uint16(len(payload)))
	copy(packet[3:], payload)
	return packet
}

func maskSummary(mask uint8) string {
	result := strings.Builder{}
	if (mask & ButtonUp) != 0 {
		result.WriteByte('U')
	}
	if (mask & ButtonDown) != 0 {
		result.WriteByte('D')
	}
	if (mask & ButtonLeft) != 0 {
		result.WriteByte('L')
	}
	if (mask & ButtonRight) != 0 {
		result.WriteByte('R')
	}
	if (mask & ButtonA) != 0 {
		result.WriteByte('A')
	}
	if (mask & ButtonB) != 0 {
		result.WriteByte('B')
	}
	if result.Len() == 0 {
		return "."
	}
	return result.String()
}

func (bot *Bot) echoDebug(mask uint8, force bool) {
	if !force && bot.frameTick%24 != 0 {
		return
	}
	fmt.Printf(
		"step=%d keys=%s pos=%d,%d intent=%s target=%s#%d@%d,%d d=%d coins=%d hearts=%d kills=%d\n",
		bot.frameTick,
		maskSummary(mask),
		bot.playerWorldX,
		bot.playerWorldY,
		bot.intent,
		bot.currentTargetLabel,
		bot.currentTargetId,
		bot.currentTargetX,
		bot.currentTargetY,
		bot.currentTargetDistance,
		bot.coinCount,
		bot.heartCount,
		bot.killCount,
	)
}

func (bot *Bot) nextChat() string {
	if bot.frameTick < bot.nextChatTick {
		return ""
	}
	bot.nextChatTick = bot.frameTick + 144
	result := strings.ToUpper(bot.intent)
	if result == "" || result == bot.lastChat {
		return ""
	}
	bot.lastChat = result
	return result
}

type wsMessage struct {
	kind int
	data []byte
	err  error
}

func acceptServerMessage(message wsMessage, bot *Bot) bool {
	if message.kind != websocket.BinaryMessage {
		return false
	}
	result := bot.applySpritePacket(message.data)
	if result {
		bot.frameTick++
	}
	return result
}

func readLoop(conn *websocket.Conn, messages chan<- wsMessage) {
	defer close(messages)
	for {
		kind, data, err := conn.ReadMessage()
		if err != nil {
			messages <- wsMessage{err: err}
			return
		}
		messages <- wsMessage{kind: kind, data: data}
	}
}

func receiveUpdates(messages <-chan wsMessage, bot *Bot) (bool, bool) {
	first, ok := <-messages
	if !ok || first.err != nil {
		return false, false
	}
	result := acceptServerMessage(first, bot)
	for drained := 0; drained < MaxDrainMessages; drained++ {
		select {
		case message, ok := <-messages:
			if !ok || message.err != nil {
				return result, false
			}
			if acceptServerMessage(message, bot) {
				result = true
			}
		default:
			return result, true
		}
	}
	return result, true
}

func botURL(host string, port int, name string) string {
	address := net.JoinHostPort(host, strconv.Itoa(port))
	u := url.URL{
		Scheme: "ws",
		Host:   address,
		Path:   PlayerWebSocketPath,
	}
	if name != "" {
		query := u.Query()
		query.Set("name", name)
		u.RawQuery = query.Encode()
	}
	return u.String()
}

func runBot(host string, port int, name string, chat bool, maxSteps int) {
	targetURL := botURL(host, port, name)
	for {
		bot := newBot()
		conn, _, err := websocket.DefaultDialer.Dial(targetURL, nil)
		if err != nil {
			time.Sleep(250 * time.Millisecond)
			continue
		}
		messages := make(chan wsMessage, MaxDrainMessages+16)
		go readLoop(conn, messages)
		lastMask := uint8(0xff)
		for {
			updated, ok := receiveUpdates(messages, bot)
			if !ok {
				break
			}
			if !updated {
				continue
			}
			nextMask := bot.decideNextMask()
			bot.echoDebug(nextMask, nextMask != lastMask)
			bot.lastMask = nextMask
			if nextMask != lastMask {
				if err := conn.WriteMessage(
					websocket.BinaryMessage,
					playerInputBlob(nextMask),
				); err != nil {
					break
				}
				lastMask = nextMask
			}
			if chat {
				text := bot.nextChat()
				if text != "" {
					if err := conn.WriteMessage(
						websocket.BinaryMessage,
						chatBlob(text),
					); err != nil {
						break
					}
				}
			}
			if maxSteps > 0 && bot.frameTick >= maxSteps {
				bot.echoDebug(nextMask, true)
				fmt.Printf(
					"done steps=%d coins=%d hearts=%d kills=%d\n",
					bot.frameTick,
					bot.coinCount,
					bot.heartCount,
					bot.killCount,
				)
				_ = conn.Close()
				return
			}
		}
		_ = conn.Close()
		time.Sleep(250 * time.Millisecond)
	}
}

func main() {
	address := flag.String("address", DefaultHost, "server address")
	port := flag.Int("port", PlayerDefaultPort, "server port")
	name := flag.String("name", "konrad", "player name")
	chat := flag.Bool("chat", false, "send status chat messages")
	maxSteps := flag.Int("max-steps", 0, "stop after this many sprite frames")
	flag.Parse()
	runBot(*address, *port, *name, *chat, *maxSteps)
}
