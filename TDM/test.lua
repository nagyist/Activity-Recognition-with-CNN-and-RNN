----------------------------------------------------------------
--  Activity-Recognition-with-CNN-and-RNN
--  https://github.com/chihyaoma/Activity-Recognition-with-CNN-and-RNN
--
--  Temporal Dynamic Model: Multidimensional LSTM and Temporal ConvNet
--  
-- 
--  Contact: Chih-Yao Ma at <cyma@gatech.edu>
----------------------------------------------------------------
local nn = require 'nn'
local sys = require 'sys'
local xlua = require 'xlua'    -- xlua provides useful tools, like progress bars
local optim = require 'optim'

print(sys.COLORS.red .. '==> defining some tools')

-- model:
local m = require 'model'
local model = m.model
local criterion = m.criterion

-- This matrix records the current confusion across classes
local confusion = optim.ConfusionMatrix(classes) 

-- Logger:
local testLogger = optim.Logger(paths.concat(opt.save,'test.log'))

-- Batch test:
local inputs = torch.Tensor(opt.batchSize, opt.inputSize, opt.rho)

local targets = torch.Tensor(opt.batchSize)
local labels = {}
local prob = {}

if opt.averagePred == true then 
	predsFrames = torch.Tensor(opt.batchSize, nClass, opt.rho-1)
end

if opt.cuda == true then
	inputs = inputs:cuda()
	targets = targets:cuda()
	if opt.averagePred == true then 
	   predsFrames = predsFrames:cuda()
	end
end

-- test function
function test(testData, testTarget)

	-- local vars
	local time = sys.clock() 
	local timer = torch.Timer()
	local dataTimer = torch.Timer()

	model:remove(1)

	-- replace the JoinTable in model with CAddTable
	model:get(2):get(1):remove(1)
	model:get(2):get(1):insert(nn.View(#opt.hiddenSize, opt.batchSize, opt.inputSize, -1),1)
	model:get(2):get(1):remove(8)
	model:get(2):get(1):add(nn.CAddTable())

	if opt.cuda == true then
		model:cuda()
	end
	-- Sets Dropout layer to have a different behaviour during evaluation.
	model:evaluate() 

	-- test over test data
	print(sys.COLORS.red .. '==> testing on test set:')

	if opt.testOnly then 
		epoch = 1
	end
	
	local top1Sum, top3Sum, lossSum = 0.0, 0.0, 0.0
	local N = 0
	for t = 1,testData:size(1),opt.batchSize do
		local dataTime = dataTimer:time().real
		-- disp progress
		xlua.progress(t, testData:size(1))

		-- create mini batch
		local idx = 1
		inputs:fill(0)
		targets:fill(0)

		for i = t,t+opt.batchSize-1 do
			if i <= testData:size(1) then
				inputs[idx] = testData[i]:float()
				targets[idx] = testTarget[i]
				idx = idx + 1
			end
		end
		local idxBound = idx - 1

		local top1, top3
		if opt.averagePred == true then 
			-- make prediction for each of the images frames, start from frame #2
			idx = 1
			for i = 2, opt.rho do
				-- extract various length of frames 
				local Index = torch.range(1, i)
				local indLong = torch.LongTensor():resize(Index:size()):copy(Index)
				local inputsPreFrames = inputs:index(3, indLong)

				-- replicate the testing data and feed into LSTM cells seperately
				inputsPreFrames = torch.repeatTensor(inputsPreFrames,#opt.hiddenSize,1,1)

				-- feedforward pass the trained model
				predsFrames[{{},{},idx}] = model:get(2):get(1):forward(inputsPreFrames)

				idx = idx + 1
			end
			-- average all the prediction across all frames
			preds = torch.mean(predsFrames, 3):squeeze()

			-- T-CNN forward
			local tcnnOutput = model:get(2):get(2):forward(inputs)

			-- add prediction from LSTM and T-CNN
			-- preds:add(tcnnOutput)

			local tmp = torch.cat(preds, tcnnOutput)
			local damn = nn.Sequential()
			damn:add(model:get(4))
			damn:add(model:get(5))

			preds = damn:forward(tmp)

			-- discard the redundant predictions and targets
			if (t + opt.batchSize - 1) > testData:size(1) then
				preds = preds:sub(1,idxBound)
			end

			top1, top3 = computeScore(preds, targets:sub(1,idxBound), 1)
			top1Sum = top1Sum + top1*idxBound
			top3Sum = top3Sum + top3*idxBound
			N = N + idxBound

			print((' | Test: [%d][%d/%d]    Time %.3f  Data %.3f  top1 %7.3f (%7.3f)  top3 %7.3f (%7.3f)'):format(
				epoch-1, t, testData:size(1), timer:time().real, dataTime, top1, top1Sum / N, top3, top3Sum / N))

			-- Get the top N class indexes and probabilities
			local topN = 3
			local probLog, predLabels = preds:topk(topN, true, true)

			-- Convert log probabilities back to [0, 1]
			probLog:exp()

			idx = 1
			for i = t,t+opt.batchSize-1 do
				if i <= testData:size(1) then
					labels[i] = {}
					prob[i] = {}
					for j = 1, topN do
						labels[i][j] = classes[predLabels[idx][j]]
						prob[i][j] = probLog[idx][j]
					end
					idx = idx + 1
				end
			end

		else
			-- test sample
			-- TODO: need to be largely modify
			preds = model:forward(inputs)
		end

		-- confusion
		for i = 1,idxBound do
			confusion:add(preds[i], targets:sub(1,idxBound)[i])
		end
	end

	-- timing
	time = sys.clock() - time
	time = time / testData:size(1)
	print("\n==> time to test 1 sample = " .. (time*1000) .. 'ms')

	timer:reset()
	dataTimer:reset()

  	-- print confusion matrix
  	print(confusion)

  	assert(#labels == testData:size(1), 'predictions dimension mismatch with testing data..')

  	-- if the performance is so far the best..
  	local bestModel = false
	if confusion.totalValid * 100 >= bestAcc then
		bestModel = true
		bestAcc = confusion.totalValid * 100
		-- save the labels and probabilities into file
		torch.save(opt.save .. '/labels.txt', labels,'ascii')
		torch.save(opt.save .. '/prob.txt', prob,'ascii')

		if opt.saveModel == true then
			checkpoints.save(epoch-1, model, optimState, bestModel, confusion.totalValid*100)
		end
	end
	print(sys.COLORS.red .. '==> Best testing accuracy = ' .. bestAcc .. '%')
	print(sys.COLORS.red .. (' * Finished epoch # %d     top1: %7.3f  top3: %7.3f\n'):format(
      epoch-1, top1Sum / N, top3Sum / N))

	-- update log/plot
	testLogger:add{['epoch'] = epoch-1, ['top-1 error'] = confusion.totalValid * 100}
	if opt.plot then
		testLogger:style{['% mean class accuracy (test set)'] = '-'}
		testLogger:plot()
	end
	confusion:zero()

	-- revert back to the original model for training again 
	model:insert(nn.Replicate(2),1)
	model:get(3):get(1):remove(1)
	model:get(3):get(1):insert(nn.View(#opt.hiddenSize, opt.batchSize/#opt.hiddenSize, opt.inputSize, -1),1)
	model:get(3):get(1):remove(8)
	model:get(3):get(1):add(nn.JoinTable(1))
	
	if opt.cuda == true then
		model:cuda()
	end
end

function computeScore(output, target)

   -- Coputes the top1 and top3 error rate
   local batchSize = output:size(1)

   local _ , predictions = output:float():sort(2, true) -- descending

   -- Find which predictions match the target
   local correct = predictions:eq(
      target:long():view(batchSize, 1):expandAs(output))

   -- Top-1 score
   local top1 = 1.0 - (correct:narrow(2, 1, 1):sum() / batchSize)

   -- Top-3 score, if there are at least 3 classes
   local len = math.min(3, correct:size(2))
   local top3 = 1.0 - (correct:narrow(2, 1, len):sum() / batchSize)

   return top1 * 100, top3 * 100
end

-- Export:
return test

