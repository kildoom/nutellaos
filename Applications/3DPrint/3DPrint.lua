
local component = require("component")
local event = require("event")
local unicode = require("unicode")
local serialization = require("serialization")
local fs = require("filesystem")

local context = require("context")
local bigLetters = require("bigLetters")
local ecs = require("ECSAPI")
local palette = require("palette")

local hologram
local printer
local gpu = component.gpu

------------------------------------------------------------------------------------------------------------------------

if component.isAvailable("hologram") then
	hologram = component.hologram
else
	ecs.error("Этой программе требуется 3D-принтер и голографический проектор 2 уровня.")
end

if component.isAvailable("printer3d") then
	printer = component.printer3d
else
	ecs.error("Этой программе требуется 3D-принтер и голографический проектор 2 уровня.")
end

------------------------------------------------------------------------------------------------------------------------

local colors = {
	drawingZoneCYKA = 0xCCCCCC,
	drawingZoneBackground = 0xFFFFFF,
	drawingZoneStartPoint = 0x262626,
	drawingZoneEndPoint = 0x555555,
	drawingZoneSelection = 0xFF5555,
	toolbarBackground = 0xEEEEEE,
	toolbarText = 0x262626,
	toolbarKeyText = 0x000000,
	toolbarValueText = 0x666666,
	toolbarBigLetters = 0x262626,
	shapeNumbersText = 0xFFFFFF,
	shapeNumbersBackground = 0xBBBBBB,
	shapeNumbersActiveBackground = ecs.colors.blue,
	shapeNumbersActiveText = 0xFFFFFF,
	toolbarInfoBackground = 0x262626,
	toolbarInfoText = 0xFFFFFF,
	toolbarButtonBackground = 0xCCCCCC,
	toolbarButtonText = 0x262626,
}

local xSize, ySize = gpu.getResolution()
local widthOfToolbar = 33
local xToolbar = xSize - widthOfToolbar + 1
local widthOfDrawingCYKA = xSize - widthOfToolbar

local currentLayer = 1
local currentShape = 1
local maxShapeCount = 24
local currentMode = 1
local modes = {
	"неактивная",
	"активная"
}
local currentTexture = "planks_oak"
local currentTint = ecs.colors.orange
local useTint = false
local showLayerOnHologram = true

local pixelWidth = 6
local pixelHeight = 3
local drawingZoneWidth = pixelWidth * 16
local drawingZoneHeight = pixelHeight * 16
local xDrawingZone = math.floor(widthOfDrawingCYKA / 2 - drawingZoneWidth / 2)
local yDrawingZone = 3

local model = {}

------------------------------------------------------------------------------------------------------------------------

local function swap(a, b)
	return b, a
end

local function correctShapeCoords(shapeNumber)
	if model.shapes[shapeNumber] then
		if model.shapes[shapeNumber][1] > model.shapes[currentShape][4] then
			model.shapes[shapeNumber][1], model.shapes[currentShape][4] = swap(model.shapes[currentShape][1], model.shapes[currentShape][4])
			model.shapes[shapeNumber][1] = model.shapes[shapeNumber][1] - 1
			model.shapes[shapeNumber][4] = model.shapes[shapeNumber][4] + 1
		end
		if model.shapes[shapeNumber][2] >= model.shapes[currentShape][5] then
			model.shapes[shapeNumber][2], model.shapes[currentShape][5] = swap(model.shapes[currentShape][2], model.shapes[currentShape][5])
			model.shapes[shapeNumber][2] = model.shapes[shapeNumber][2] - 1
			model.shapes[shapeNumber][5] = model.shapes[shapeNumber][5] + 1
		end
		if model.shapes[shapeNumber][3] > model.shapes[currentShape][6] then
			model.shapes[shapeNumber][3], model.shapes[currentShape][6] = swap(model.shapes[currentShape][3], model.shapes[currentShape][6])
			model.shapes[shapeNumber][3] = model.shapes[shapeNumber][3] - 1
			model.shapes[shapeNumber][6] = model.shapes[shapeNumber][6] + 1
		end
	end
end

local function fixModelArray()
	model.label = model.label or "Sample label"
	model.tooltip = model.tooltip or "Sample tooltip"
	model.lightLevel = model.lightLevel or 0
	model.emitRedstone = model.emitRedstone or false
	model.buttonMode = model.buttonMode or false
	model.collidable = model.collidable or {true, true}
	model.shapes = model.shapes or {}
end

--Объекты для тача
local obj = {}
local function newObj(class, name, ...)
	obj[class] = obj[class] or {}
	obj[class][name] = {...}
end

local function drawShapeNumbers(x, y)
	local counter = 1
	local xStart = x

	for j = 1, 4 do
		for i = 1, 6 do
			if currentShape == counter then
				newObj("ShapeNumbers", counter, ecs.drawButton(x, y, 4, 1, tostring(counter), colors.shapeNumbersActiveBackground, colors.shapeNumbersActiveText))
			else
				newObj("ShapeNumbers", counter, ecs.drawButton(x, y, 4, 1, tostring(counter), colors.shapeNumbersBackground, colors.shapeNumbersText))
			end

			x = x + 5
			counter = counter + 1
		end
		x = xStart
		y = y + 2
	end
end

local function toolBarInfoLine(y, text)
	ecs.square(xToolbar, y, widthOfToolbar, 1, colors.toolbarInfoBackground)
	ecs.colorText(xToolbar + 1, y, colors.toolbarInfoText, text)
end

local function centerText(y, color, text)
	local x = math.floor(xToolbar + widthOfToolbar / 2 - unicode.len(text) / 2)
	ecs.colorTextWithBack(x, y, color, colors.toolbarBackground, text)
end

local function addButton(y, back, fore, text)
	newObj("ToolbarButtons", text, ecs.drawButton(xToolbar + 2, y, widthOfToolbar - 4, 3, text, back, fore))
end

local function printKeyValue(x, y, keyColor, valueColor, key, value, limit)
	local totalLength = unicode.len(key .. ": " .. value) 
	if totalLength > limit then
		value = unicode.sub(value, 1, limit - unicode.len(key .. ": ") - 1) .. "…"
	end
	gpu.setForeground(keyColor)
	gpu.set(x, y, key .. ":")
	gpu.setForeground(valueColor)
	gpu.set(x + unicode.len(key) + 2, y, value)
end

local function getShapeCoords()
	local coords = "элемент не создан"
	if model.shapes[currentShape] then
		coords = "(" .. model.shapes[currentShape][1] .. "," .. model.shapes[currentShape][2] .. "," .. model.shapes[currentShape][3] .. ");(" .. model.shapes[currentShape][4] .. "," .. model.shapes[currentShape][5] .. "," .. model.shapes[currentShape][6] .. ")"
	end
	return coords
end

local function fixNumber(number)
	if number < 10 then number = "0" .. number end
	return tostring(number)
end

local function drawToolbar()
	ecs.square(xToolbar, 1, widthOfToolbar, ySize, colors.toolbarBackground)

	local x = xToolbar + 8
	local y = 3

	--Текущий слой
	bigLetters.drawString(x, y, colors.toolbarBigLetters, fixNumber(currentLayer))
	y = y + 6
	centerText(y, colors.toolbarText, "Текущая высота")

	--Управление элементом
	y = y + 2
	x = xToolbar + 2
	toolBarInfoLine(y, "Управление моделью"); y = y + 2
	gpu.setBackground(colors.toolbarBackground)
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Имя", model.label, widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Описание", model.tooltip, widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Как кнопка", tostring(model.buttonMode), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Редстоун-сигнал", tostring(model.emitRedstone), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Коллизия", tostring(model.collidable[currentMode]), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Уровень света", tostring(model.lightLevel), widthOfToolbar - 4); y = y + 1
	y = y + 1
	printKeyValue(x, y, ecs.colors.blue, colors.toolbarValueText, "Состояние", modes[currentMode], widthOfToolbar - 4); y = y + 1
	y = y + 1
	addButton(y, colors.toolbarButtonBackground, colors.toolbarButtonText, "Изменить параметры"); y = y + 4
	addButton(y, colors.toolbarButtonBackground, colors.toolbarButtonText, "Напечатать"); y = y + 4
	toolBarInfoLine(y, "Управление элементом " .. currentShape); y = y + 2
	gpu.setBackground(colors.toolbarBackground)
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Текстура", tostring(currentTexture), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Оттенок", ecs.HEXtoString(currentTint, 6, true), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Использовать оттенок", tostring(useTint), widthOfToolbar - 4); y = y + 1
	printKeyValue(x, y, colors.toolbarKeyText, colors.toolbarValueText, "Позиция", getShapeCoords(), widthOfToolbar - 4); y = y + 2
	addButton(y, colors.toolbarButtonBackground, colors.toolbarButtonText, "Изменить параметры "); y = y + 4

	--Элементы
	toolBarInfoLine(y, "Выбор элемента"); y = y + 2
	drawShapeNumbers(x, y)
	y = y + 8
end

local function drawTopMenu(selected)
	obj["TopMenu"] = ecs.drawTopMenu(1, 1, xSize - widthOfToolbar, colors.toolbarBackground, selected, {"Файл", 0x262626}, {"Проектор", 0x262626}, {"О программе", 0x262626})
end

local function renderCurrentLayerOnHologram(xStart, yStart, zStart)
	if showLayerOnHologram then
		for i = xStart, xStart + 16 do
			hologram.set(i, yStart + currentLayer - 1, zStart - 1, 3)
			hologram.set(i, yStart + currentLayer - 1, zStart + 17, 3)
		end

		for i = (zStart-1), (zStart + 17) do
			hologram.set(xStart - 1, yStart + currentLayer - 1, i, 3)
			hologram.set(xStart + 17, yStart + currentLayer - 1, i, 3)
		end
	end
end

local function drawModelOnHologram()
	local xStart, yStart, zStart = 16,4,16
	hologram.clear()

	for shape in pairs(model.shapes) do
		if (currentMode == 2 and model.shapes[shape].state) or (currentMode == 1 and not model.shapes[shape].state) then
			if model.shapes[shape] then
				for x = model.shapes[shape][1], model.shapes[shape][4] do
					for y = model.shapes[shape][2], (model.shapes[shape][5] - 1) do
						for z = model.shapes[shape][3], model.shapes[shape][6] do
							--Эта хуйня для того, чтобы в разных режимах не ебало мозг
							if (model.shapes[shape].state and currentMode == 2) or (not model.shapes[shape].state and currentMode == 1) then
								if shape == currentShape then
									hologram.set(xStart + x, yStart + y, zStart + z, 2)
								else
									hologram.set(xStart + x, yStart + y, zStart + z, 1)
								end
							end
						end
					end
				end
			end
		end
	end

	renderCurrentLayerOnHologram(xStart, yStart, zStart)
end

local function printModel()
	printer.reset()
	printer.setLabel(model.label)
	printer.setTooltip(model.tooltip)
	printer.setCollidable(model.collidable[1], model.collidable[2])
	printer.setLightLevel(model.lightLevel)
	printer.setRedstoneEmitter(model.emitRedstone)
	printer.setButtonMode(model.buttonMode)
	for i in pairs(model.shapes) do
		printer.addShape(
			model.shapes[i][1],
			model.shapes[i][2],
			model.shapes[i][3],
			model.shapes[i][4],
			model.shapes[i][5],
			model.shapes[i][6], 
			model.shapes[i].texture,
			model.shapes[i].state,
			model.shapes[i].tint
		)
	end
	local success, reason = printer.commit(1)
	if not success then
		ecs.error("Ошибка печати: " .. reason)
	end
end

local function drawPixel(x, y, width, height, color)
	gpu.setBackground(color)
	gpu.fill(xDrawingZone + x * pixelWidth - pixelWidth, yDrawingZone + y * pixelHeight - pixelHeight, width * pixelWidth, height * pixelHeight, " ")
end

local function drawDrawingZone()
	ecs.square(xDrawingZone, yDrawingZone, drawingZoneWidth, drawingZoneHeight, colors.drawingZoneBackground)
	
	if model.shapes[currentShape] then

		if not ((model.shapes[currentShape].state and currentMode == 2) or (not model.shapes[currentShape].state and currentMode == 1)) then
			return
		end

		local selectionStartPoint = {}
		local selectionEndPoint = {}

		selectionStartPoint.x = model.shapes[currentShape][1] + 1
		selectionStartPoint.y = model.shapes[currentShape][2] + 1
		selectionStartPoint.z = model.shapes[currentShape][3] + 1
		selectionEndPoint.x = model.shapes[currentShape][4]
		selectionEndPoint.y = model.shapes[currentShape][5]
		selectionEndPoint.z = model.shapes[currentShape][6]

		if selectionStartPoint.y <= currentLayer and selectionEndPoint.y  >= currentLayer then
			drawPixel(selectionStartPoint.x, selectionStartPoint.z, selectionEndPoint.x - selectionStartPoint.x + 1, selectionEndPoint.z - selectionStartPoint.z + 1, colors.drawingZoneSelection)
		end

		if selectionStartPoint.y == currentLayer then
			drawPixel(selectionStartPoint.x, selectionStartPoint.z, 1, 1, colors.drawingZoneStartPoint)
		end

		if selectionEndPoint.y == currentLayer then
			drawPixel(selectionEndPoint.x, selectionEndPoint.z, 1, 1, colors.drawingZoneEndPoint)
		end
	end
end

local function drawAll()
	ecs.square(1, 2, xSize, ySize, colors.drawingZoneCYKA)
	drawDrawingZone()
	drawToolbar()
	drawTopMenu(0)
end

local function save(path)
	fs.makeDirectory(fs.path(path) or "")
	local file = io.open(path, "w")
	file:write(serialization.serialize(model))
	file:close()
end

local function open(path)
	if fs.exists(path) then
		if ecs.getFileFormat(path) == ".3dm" then
			local file = io.open(path, "r")
			model = serialization.unserialize(file:read("*a"))
			fixModelArray()
			file:close()
			drawAll()
			drawModelOnHologram()
		else
			ecs.error("Файл имеет неизвестный формат. Поддерживаются только модели в формате .3dm.")
		end
	else
		ecs.error("Файл \"" .. path .. "\" не существует")
	end
end

------------------------------------------------------------------------------------------------------------------------

model = {}

fixModelArray()
drawAll()
drawModelOnHologram()

local startPointSelected = false
local xShapeStart, yShapeStart, zShapeStart, xShapeEnd, yShapeEnd, zShapeEnd 

while true do
	local e = { event.pull() }
	if e[1] == "touch" then
		--Если кликнули в зону рисования
		if ecs.clickedAtArea(e[3], e[4], xDrawingZone, yDrawingZone, xDrawingZone + drawingZoneWidth - 1, yDrawingZone + drawingZoneHeight - 1) then
			if not startPointSelected then
				xShapeStart = math.ceil((e[3] - xDrawingZone + 1) / pixelWidth)
				yShapeStart = currentLayer
				zShapeStart = math.ceil((e[4] - yDrawingZone + 1) / pixelHeight)
				
				startPointSelected = true
				model.shapes[currentShape] = nil
				ecs.square(xDrawingZone, yDrawingZone, drawingZoneWidth, drawingZoneHeight, colors.drawingZoneBackground)
			
				drawPixel(xShapeStart, zShapeStart, 1, 1, colors.drawingZoneStartPoint)
			else
				xShapeEnd = math.ceil((e[3] - xDrawingZone + 1) / pixelWidth)
				yShapeEnd = currentLayer
				zShapeEnd = math.ceil((e[4] - yDrawingZone + 1) / pixelHeight)
				
				drawPixel(xShapeEnd, zShapeEnd, 1, 1, colors.drawingZoneEndPoint)
				startPointSelected = false

				model.shapes[currentShape] = {
					xShapeStart - 1,
					yShapeStart - 1,
					zShapeStart - 1,
					xShapeEnd,
					yShapeEnd,
					zShapeEnd,
					texture = currentTexture,
				}

				if currentMode == 2 then model.shapes[currentShape].state = true end
				if useTint then model.shapes[currentShape].tint = currentTint end

				correctShapeCoords(currentShape)

				drawAll()
				drawModelOnHologram()
			end
		else
			for key in pairs(obj.ShapeNumbers) do
				if ecs.clickedAtArea(e[3], e[4], obj.ShapeNumbers[key][1], obj.ShapeNumbers[key][2], obj.ShapeNumbers[key][3], obj.ShapeNumbers[key][4]) then
					currentShape = key
					drawDrawingZone()
					drawToolbar()
					drawModelOnHologram()
					break
				end
			end

			for key in pairs(obj.ToolbarButtons) do
				if ecs.clickedAtArea(e[3], e[4], obj.ToolbarButtons[key][1], obj.ToolbarButtons[key][2], obj.ToolbarButtons[key][3], obj.ToolbarButtons[key][4]) then
					ecs.drawButton(obj.ToolbarButtons[key][1], obj.ToolbarButtons[key][2], widthOfToolbar - 4, 3, key, ecs.colors.blue, 0xFFFFFF)
					os.sleep(0.2)

					if key == "Напечатать" then
						printModel()
					elseif key == "Изменить параметры" then
						local data = ecs.universalWindow("auto", "auto", 36, 0x262626, true,
							{"EmptyLine"},
							{"CenterText", ecs.colors.orange, "Параметры модели"},
							{"EmptyLine"},
							{"Input", 0xFFFFFF, ecs.colors.orange, model.label},
							{"Input", 0xFFFFFF, ecs.colors.orange, model.tooltip},
							{"Selector", 0xFFFFFF, ecs.colors.orange, "Неактивная", "Активная"},
							{"EmptyLine"},
							{"Switch", ecs.colors.orange, 0xffffff, 0xFFFFFF, "Как кнопка", model.buttonMode},
							{"EmptyLine"},
							{"Switch", ecs.colors.orange, 0xffffff, 0xFFFFFF, "Редстоун-сигнал", model.emitRedstone},
							{"EmptyLine"},
							{"Switch", ecs.colors.orange, 0xffffff, 0xFFFFFF, "Коллизия", model.collidable[currentMode]},
							{"EmptyLine"},
							{"Slider", 0xFFFFFF, ecs.colors.orange, 0, 15, model.lightLevel, "Уровень света: ", ""},
							{"EmptyLine"},
							{"Button", {ecs.colors.orange, 0xffffff, "OK"}, {0x999999, 0xffffff, "Отмена"}}
						)

						if data[8] == "OK" then
							model.label = data[1] or "Sample label"
							model.tooltip = data[2] or "Sample tooltip"
							if data[3] == "Активная" then
								currentMode = 2
							else
								currentMode = 1
							end
							model.buttonMode = data[4]
							model.emitRedstone = data[5]
							model.collidable[currentMode] = data[6]
							model.lightLevel = data[7]
						end

					elseif key == "Изменить параметры " then
						local data = ecs.universalWindow("auto", "auto", 36, 0x262626, true,
							{"EmptyLine"},
							{"CenterText", ecs.colors.orange, "Параметры элемента"},
							{"EmptyLine"},
							{"Input", 0xFFFFFF, ecs.colors.orange, currentTexture},
							{"Color", "Оттенок", currentTint},
							{"EmptyLine"},
							{"Switch", ecs.colors.orange, 0xffffff, 0xFFFFFF, "Использовать оттенок", useTint},
							{"EmptyLine"},
							{"Button", {ecs.colors.orange, 0xffffff, "OK"}, {0x999999, 0xffffff, "Отмена"}}
						)

						if data[4] == "OK" then
							currentTexture = data[1]
							currentTint = data[2]
							useTint = data[3]
						end
					end

					drawAll()
					drawModelOnHologram()	
					break
				end
			end

			for key in pairs(obj.TopMenu) do
				if ecs.clickedAtArea(e[3], e[4], obj.TopMenu[key][1], obj.TopMenu[key][2], obj.TopMenu[key][3], obj.TopMenu[key][4]) then
					ecs.drawButton(obj.TopMenu[key][1] - 1, obj.TopMenu[key][2], unicode.len(key) + 2, 1, key, ecs.colors.blue, 0xFFFFFF)

					local action
					if key == "Файл" then
						action = context.menu(obj.TopMenu[key][1] - 1, obj.TopMenu[key][2] + 1, {"Новый"}, "-", {"Открыть"}, {"Сохранить"}, "-", {"Выход"})
					elseif key == "Проектор" then
						action = context.menu(obj.TopMenu[key][1] - 1, obj.TopMenu[key][2] + 1, {"Масштаб"}, {"Изменить палитру"}, "-", {"Включить показ слоя"}, {"Отключить показ слоя"}, "-", {"Включить вращение"}, {"Отключить вращение"})
					elseif key == "О программе" then
						ecs.universalWindow("auto", "auto", 36, 0x262626, true, 
							{"EmptyLine"},
							{"CenterText", ecs.colors.orange, "3DPrint v3.0"}, 
							{"EmptyLine"},
							{"CenterText", 0xFFFFFF, "Автор:"},
							{"CenterText", 0xBBBBBB, "Тимофеев Игорь"},
							{"CenterText", 0xBBBBBB, "vk.com/id7799889"},
							{"EmptyLine"},
							{"CenterText", 0xFFFFFF, "Тестеры:"},
							{"CenterText", 0xBBBBBB, "Семёнов Сeмён"}, 
							{"CenterText", 0xBBBBBB, "vk.com/day_z_utes"},
							{"CenterText", 0xBBBBBB, "Бесфамильный Яков"},
							{"CenterText", 0xBBBBBB, "vk.com/mathem"},
							{"EmptyLine"},
							{"Button", {ecs.colors.orange, 0xffffff, "OK"}}
						)
					end

					if action == "Сохранить" then
						local data = ecs.universalWindow("auto", "auto", 30, ecs.windowColors.background, true, {"EmptyLine"}, {"CenterText", 0x262626, "Сохранить как"}, {"EmptyLine"}, {"Input", 0x262626, 0x880000, "Путь"}, {"Selector", 0x262626, 0x880000, ".3dm"}, {"EmptyLine"}, {"Button", {0x888888, 0xffffff, "OK"}, {0xaaaaaa, 0xffffff, "Отмена"}})
						if data[3] == "OK" then
							data[1] = data[1] or "Untitled"
							local filename = data[1] .. data[2]
							save(filename)
						end
					elseif action == "Открыть" then
						local data = ecs.universalWindow("auto", "auto", 30, ecs.windowColors.background, true, {"EmptyLine"}, {"CenterText", 0x262626, "Открыть"}, {"EmptyLine"}, {"Input", 0x262626, 0x880000, "Путь"}, {"EmptyLine"}, {"Button", {0xbbbbbb, 0xffffff, "OK"}})
						open(data[1])
					elseif action == "Новый" then
						model = {}
						currentLayer = 1
						currentShape = 1
						fixModelArray()
						drawAll()
						drawModelOnHologram()
					elseif action == "Выход" then
						ecs.prepareToExit()
						return
					elseif action == "Масштаб" then
						local data = ecs.universalWindow("auto", "auto", 36, 0x262626, true, 
							{"EmptyLine"},
							{"CenterText", ecs.colors.orange, "Изменить масштаб"},
							{"EmptyLine"}, 
							{"Slider", ecs.colors.white, ecs.colors.orange, 1, 100, math.ceil(hologram.getScale() * 100 / 4), "", "%"},
							{"EmptyLine"},
							{"Button", {ecs.colors.orange, 0xffffff, "OK"}, {0x999999, 0xffffff, "Отмена"}}
						)

						if data[2] == "OK" then
							hologram.setScale(data[1] * 4 / 100)
						end
					elseif action == "Изменить палитру" then
						local data = ecs.universalWindow("auto", "auto", 36, 0x262626, true,
							{"EmptyLine"},
							{"CenterText", ecs.colors.orange, "Палитра проектора"},
							{"EmptyLine"},
							{"Color", "Цвет активного элемента", hologram.getPaletteColor(1)},
							{"Color", "Цвет других элементов", hologram.getPaletteColor(2)},
							{"Color", "Цвет рамки высоты", hologram.getPaletteColor(3)},
							{"EmptyLine"},
							{"Button", {ecs.colors.orange, 0xffffff, "OK"}, {0x999999, 0xffffff, "Отмена"}}
						)

						if data[4] == "OK" then
							for i = 1, 3 do hologram.setPaletteColor(i, data[i]) end
						end
					elseif action == "Включить показ слоя" then
						showLayerOnHologram = true
						drawModelOnHologram()
					elseif action == "Отключить показ слоя" then
						showLayerOnHologram = false
						drawModelOnHologram()
					elseif action == "Включить вращение" then
						hologram.setRotationSpeed(15, 0, 23, 0)
					elseif action == "Отключить вращение" then
						hologram.setRotationSpeed(0, 0, 0, 0)
					end

					drawTopMenu()
				end
			end
		end
	elseif e[1] == "scroll" then
		if e[5] == 1 then
			if currentLayer < 16 then
				currentLayer = currentLayer + 1
				drawAll()
				drawModelOnHologram()
			end
		else
			if currentLayer > 1 then
				currentLayer = currentLayer - 1
				drawAll()
				drawModelOnHologram()
			end
		end
	end
end

















