--------------------------------------------------------------------------------
-- DataSetLabelMe: A class to handle datasets from LabelMe (and other segmentation
--                 based datasets).
--
-- Provides lots of options to cache (on disk) datasets, precompute
-- segmentation masks, shuffle samples, extract subpatches, ...
--
-- Authors: Clement Farabet, Benoit Corda
--------------------------------------------------------------------------------

local DataSetLabelMe = torch.class('DataSetLabelMe')

local path_images = 'Images'
local path_annotations = 'Annotations'
local path_masks = 'Masks'

function DataSetLabelMe:__init(...)
   -- check args
   xlua.unpack_class(
      self,
      {...},
      'DataSetLabelMe',
      'Creates a DataSet from standard LabelMe directories (Images+Annotations)',
      {arg='path', type='string', help='path to LabelMe directory', req=true},
      {arg='nbClasses', type='number', help='number of classes in dataset', default=1},
      {arg='classNames', type='table', help='list of class names', default={'no name'}},
      {arg='nbRawSamples', type='number', help='number of images'},
      {arg='rawSampleMaxSize', type='number', help='resize all images to fit in a MxM window'},
      {arg='rawSampleSize', type='table', help='resize all images precisely: {w=,h=}}'},
      {arg='nbPatchPerSample', type='number', help='number of patches to extract from each image', default=100},
      {arg='patchSize', type='number', help='size of patches to extract from images', default=64},
      {arg='samplingMode', type='string', help='patch sampling method: random | equal', default='random'},
      {arg='labelType', type='string', help='type of label returned: center | pixelwise', default='center'},
      {arg='labelGenerator', type='function', help='a function to generate sample+target (bypasses labelType)'},
      {arg='infiniteSet', type='boolean', help='if true, the set can be indexed to infinity, looping around samples', default=false},
      {arg='classToSkip', type='number', help='index of class to skip during sampling', default=0},
      {arg='preloadSamples', type='boolean', help='if true, all samples are preloaded in memory', default=false},
      {arg='cacheFile', type='string', help='path to cache file (once cached, loading is much faster)'},
      {arg='verbose', type='boolean', help='dumps information', default=false}
   )

   -- fixed parameters
   self.colorMap = image.colormap(self.nbClasses)
   self.rawdata = {}
   self.currentIndex = -1

   --location of the patch in the img
   self.currentX = 0
   self.currentY = 0

   -- parse dir structure
   print('<DataSetLabelMe> loading LabelMe dataset from '..self.path)
   for folder in paths.files(paths.concat(self.path,path_images)) do
      if folder ~= '.' and folder ~= '..' then
         for file in paths.files(paths.concat(self.path,path_images,folder)) do
            if file ~= '.' and file ~= '..' then
               local filepng = file:gsub('jpg$','png')
               local filexml = file:gsub('jpg$','xml')
               local imgf = paths.concat(self.path,path_images,folder,file)
               local maskf = paths.concat(self.path,path_masks,folder,filepng)
               local annotf = paths.concat(self.path,path_annotations,folder,filexml)
               local size_c, size_y, size_x = image.getJPGsize(imgf)
               table.insert(self.rawdata, {imgfile=imgf,
                                           maskfile=maskf,
                                           annotfile=annotf,
                                           size={size_c, size_y, size_x}})
            end
         end
      end
   end

   -- nb samples: user defined or max
   self.nbRawSamples = self.nbRawSamples or #self.rawdata

   -- extract some info (max sizes)
   self.maxY = self.rawdata[1].size[2]
   self.maxX = self.rawdata[1].size[3]
   for i = 2,self.nbRawSamples do
      if self.maxX < self.rawdata[i].size[3] then
         self.maxX = self.rawdata[i].size[3]
      end
      if self.maxY < self.rawdata[i].size[2] then
         self.maxY = self.rawdata[i].size[2]
      end
   end
   -- and nb of samples obtainable (this is overcomplete ;-)
   self.nbSamples = self.nbPatchPerSample * self.nbRawSamples

   -- max size ?
   if not self.rawSampleMaxSize then
      self.rawSampleMaxSize = math.max(self.rawSampleSize.w,self.rawSampleSize.h)
   end
   local maxXY = math.max(self.maxX, self.maxY)
   if maxXY < self.rawSampleMaxSize then
      self.rawSampleMaxSize = maxXY
   end

   -- some info
   if self.verbose then
      print(self)
   end

   -- sampling mode
   if self.samplingMode == 'equal' or self.samplingMode == 'random' then
      self:parseAllMasks()
      if self.samplingMode == 'random' then
         -- get the number of usable patches
         self.nbRandomPatches = 0
         for i,v in ipairs(self.tags) do
            if i ~= self.classToSkip then
               self.nbRandomPatches = self.nbRandomPatches + v.size
            end
         end
         -- create shuffle table
         self.randomLookup = torch.ByteTensor(self.nbRandomPatches)
         local idx = 1
         for i,v in ipairs(self.tags) do
            if i ~= self.classToSkip and v.size > 0 then
               self.randomLookup:narrow(1,idx,v.size):fill(i)
               idx = idx + v.size
            end
         end
      end
   else
      error('ERROR <DataSetLabelMe> unknown sampling mode')
   end

   -- preload ?
   if self.preloadSamples then
      self:preload()
   end
end

function DataSetLabelMe:size()
   return self.nbSamples
end

function DataSetLabelMe:__tostring__()
   local str = 'DataSetLabelMe:\n'
   str = str .. '  + path : '..self.path..'\n'
   if self.cacheFile then
      str = str .. '  + cache files : [path]/'..self.cacheFile..'-[tags|samples]\n'
   end
   str = str .. '  + nb samples : '..self.nbRawSamples..'\n'
   str = str .. '  + nb generated patches : '..self.nbSamples..'\n'
   if self.infiniteSet then
      str = str .. '  + infinite set (actual nb of samples >> set:size())\n'
   end
   if self.rawSampleMaxSize then
      str = str .. '  + samples are resized to fit in a '
      str = str .. self.rawSampleMaxSize .. 'x' .. self.rawSampleMaxSize .. ' tensor'
      str = str .. ' [max raw size = ' .. self.maxX .. 'x' .. self.maxY .. ']\n'
      if self.rawSampleSize then
         str = str .. '  + imposed ratio of ' .. self.rawSampleSize.w .. 'x' .. self.rawSampleSize.h .. '\n'
      end
   end
   str = str .. '  + patches size : ' .. self.patchSize .. 'x' .. self.patchSize .. '\n'
   if self.classToSkip ~= 0 then
      str = str .. '  + unused class : ' .. self.classNames[self.classToSkip] .. '\n'
   end
   str = str .. '  + sampling mode : ' .. self.samplingMode .. '\n'
   if not self.labelGenerator then
      str = str .. '  + label type : ' .. self.labelType .. '\n'
   else
      str = str .. '  + label type : generated by user function \n'
   end
   str = str .. '  + '..self.nbClasses..' categories : '
   for i = 1,#self.classNames-1 do
      str = str .. self.classNames[i] .. ' | '
   end
   str = str .. self.classNames[#self.classNames]
   return str
end

function DataSetLabelMe:__index__(key)
   -- generate sample + target at index 'key':
   if type(key)=='number' then

      -- select sample, according to samplingMode
      local box_size = self.patchSize
      local ctr_target, tag_idx
      if self.samplingMode == 'random' then
         -- get indexes from random table
         ctr_target = self.randomLookup[math.random(1,self.nbRandomPatches)]
         tag_idx = math.floor(math.random(0,self.tags[ctr_target].size-1)/3)*3+1
      elseif self.samplingMode == 'equal' then
         -- equally sample each category:
         ctr_target = ((key-1) % (self.nbClasses)) + 1
         while self.tags[ctr_target].size == 0 or ctr_target == self.classToSkip do
            -- no sample in that class, replacing with random patch
            ctr_target = math.floor(random.uniform(1,self.nbClasses))
         end
         local nbSamplesPerClass = math.ceil(self.nbSamples / self.nbClasses)
         tag_idx = math.floor((key*nbSamplesPerClass-1)/self.nbClasses) + 1
         tag_idx = ((tag_idx-1) % (self.tags[ctr_target].size/3))*3 + 1
      end

      -- generate patch
      self:loadSample(self.tags[ctr_target].data[tag_idx+2])
      local full_sample = self.currentSample
      local full_mask = self.currentMask
      local ctr_x = self.tags[ctr_target].data[tag_idx]
      local ctr_y = self.tags[ctr_target].data[tag_idx+1]
      local box_x = math.floor(ctr_x - box_size/2) + 1
      self.currentX = box_x/full_sample:size(3)
      local box_y = math.floor(ctr_y - box_size/2) + 1
      self.currentY = box_y/full_sample:size(2)

      -- extract sample + mask:
      local sample = full_sample:narrow(2,box_y,box_size):narrow(3,box_x,box_size)
      local mask = full_mask:narrow(1,box_y,box_size):narrow(2,box_x,box_size)

      -- finally, generate the target, either using an arbitrary user function,
      -- or a built-in label type
      if self.labelGenerator then
         -- call user function to generate sample+label
         local ret = self:labelGenerator(full_sample, full_mask, sample, mask,
                                         ctr_target, ctr_x, ctr_y, box_x, box_y, box_size)
         return ret, true

      elseif self.labelType == 'center' then
         -- generate label vector for patch 
         local vector = torch.Tensor(self.nbClasses):fill(-1)
         vector[ctr_target] = 1
         return {sample, vector}, true

      elseif self.labelType == 'pixelwise' then
         -- generate pixelwise annotation
         return {sample, mask}, true

      else
         return false
      end
   end
   return rawget(self,key)
end

function DataSetLabelMe:loadSample(index)
   if self.preloadedDone then
      if index ~= self.currentIndex then
         -- clean up
         self.currentSample = nil
         self.currentMask = nil
         collectgarbage()
         -- load new sample
         self.currentSample = torch.Tensor(self.preloaded.samples[index]:size())
         self.currentSample:copy(self.preloaded.samples[index]):mul(1/255)
         self.currentMask = torch.Tensor(self.preloaded.masks[index]:size())
         self.currentMask:copy(self.preloaded.masks[index])
         -- remember index
         self.currentIndex = index
      end
   elseif index ~= self.currentIndex then
      -- clean up
      self.currentSample = nil
      self.currentMask = nil
      collectgarbage()
      -- load image
      local img_loaded = image.load(self.rawdata[index].imgfile)
      local mask_loaded = image.load(self.rawdata[index].maskfile)[1]
      -- resize ?
      if self.rawSampleSize then
         -- resize precisely
         local w = self.rawSampleSize.w
         local h = self.rawSampleSize.h
         self.currentSample = torch.Tensor(img_loaded:size(1),h,w)
         image.scale(img_loaded, self.currentSample, 'bilinear')
         self.currentMask = torch.Tensor(h,w)
         image.scale(mask_loaded, self.currentMask, 'simple')

      elseif self.rawSampleMaxSize and (self.rawSampleMaxSize < img_loaded:size(3)
                                     or self.rawSampleMaxSize < img_loaded:size(2)) then
         -- resize to fit in bounding box
         local w,h
         if img_loaded:size(3) >= img_loaded:size(2) then
            w = self.rawSampleMaxSize
            h = math.floor((w*img_loaded:size(2))/img_loaded:size(3))
         else
            h = self.rawSampleMaxSize
            w = math.floor((h*img_loaded:size(3))/img_loaded:size(2))
         end
         self.currentSample = torch.Tensor(img_loaded:size(1),h,w)
         image.scale(img_loaded, self.currentSample, 'bilinear')
         self.currentMask = torch.Tensor(h,w)
         image.scale(mask_loaded, self.currentMask, 'simple')
      else
         self.currentSample = img_loaded
         self.currentMask = mask_loaded
      end
      -- process mask
      self.currentMask:mul(self.nbClasses-1):add(0.5):floor():add(1)
      self.currentIndex = index
   end
end

function DataSetLabelMe:preload(saveFile)
   -- if cache file exists, just retrieve images from it
   if self.cacheFile
      and paths.filep(paths.concat(self.path,self.cacheFile..'-samples')) then
      print('<DataSetLabelMe> retrieving saved samples from :'
            .. paths.concat(self.path,self.cacheFile..'-samples')
         .. ' [delete file to force new scan]')
      local file = torch.DiskFile(paths.concat(self.path,self.cacheFile..'-samples'), 'r')
      file:binary()
      self.preloaded = file:readObject()
      file:close()
      self.preloadedDone = true
      return
   end
   print('<DataSetLabelMe> preloading all images')
   self.preloaded = {samples={}, masks={}}
   for i = 1,self.nbRawSamples do
      xlua.progress(i,self.nbRawSamples)
      -- load samples, and store them in raw byte tensors (min memory footprint)
      self:loadSample(i)
      local rawTensor = torch.Tensor(self.currentSample:size()):copy(self.currentSample:mul(255))
      local rawMask = torch.Tensor(self.currentMask:size()):copy(self.currentMask)
      -- insert them in our list
      table.insert(self.preloaded.samples, rawTensor)
      table.insert(self.preloaded.masks, rawMask)
   end
   self.preloadedDone = true
   -- optional cache file
   if saveFile then
      self.cacheFile = saveFile
   end
   -- if cache file given, serialize list of tags to it
   if self.cacheFile then
      print('<DataSetLabelMe> saving samples to cache file: '
            .. paths.concat(self.path,self.cacheFile..'-samples'))
      local file = torch.DiskFile(paths.concat(self.path,self.cacheFile..'-samples'), 'w')
      file:binary()
      file:writeObject(self.preloaded)
      file:close()
   end
end

function DataSetLabelMe:parseMask(existing_tags)
   local tags
   if not existing_tags then
      tags = {}
      local storage
      for i = 1,self.nbClasses do
         storage = torch.ShortStorage(self.rawSampleMaxSize*self.rawSampleMaxSize*3)
         tags[i] = {data=storage, size=0}
      end
   else
      tags = existing_tags
      -- make sure each tag list is large enough to hold the incoming data
      for i = 1,self.nbClasses do
         if ((tags[i].size + (self.rawSampleMaxSize*self.rawSampleMaxSize*3)) >
          tags[i].data:size()) then
            tags[i].data:resize(tags[i].size+(self.rawSampleMaxSize*self.rawSampleMaxSize*3),true)
         end
      end
   end
   local mask = self.currentMask
   local x_start = math.ceil(self.patchSize/2)
   local x_end = mask:size(2) - math.ceil(self.patchSize/2)
   local y_start = math.ceil(self.patchSize/2)
   local y_end = mask:size(1) - math.ceil(self.patchSize/2)
   mask.nn.DataSetLabelMe_extract(tags, mask, x_start, x_end, y_start, y_end, self.currentIndex)
   return tags
end

function DataSetLabelMe:parseAllMasks(saveFile)
   -- if cache file exists, just retrieve tags from it
   if self.cacheFile and paths.filep(paths.concat(self.path,self.cacheFile..'-tags')) then
      print('<DataSetLabelMe> retrieving saved tags from :' .. paths.concat(self.path,self.cacheFile..'-tags')
         .. ' [delete file to force new scan]')
      local file = torch.DiskFile(paths.concat(self.path,self.cacheFile..'-tags'), 'r')
      file:binary()
      self.tags = file:readObject()
      file:close()
      return
   end
   -- parse tags, long operation
   print('<DataSetLabelMe> parsing all masks to generate list of tags')
   print('<DataSetLabelMe> WARNING: this operation could allocate up to '..
         math.ceil(self.nbRawSamples*self.rawSampleMaxSize*self.rawSampleMaxSize*
                   3*2/1024/1024)..'MB')
   self.tags = nil
   for i = 1,self.nbRawSamples do
      xlua.progress(i,self.nbRawSamples)
      self:loadSample(i)
      self.tags = self:parseMask(self.tags)
   end
   -- report
   print('<DataSetLabelMe> nb of patches extracted per category:')
   for i = 1,self.nbClasses do
      print('  ' .. i .. ' - ' .. self.tags[i].size / 3)
   end
   -- optional cache file
   if saveFile then
      self.cacheFile = saveFile
   end
   -- if cache file exists, serialize list of tags to it
   if self.cacheFile then
      print('<DataSetLabelMe> saving tags to cache file: ' .. paths.concat(self.path,self.cacheFile..'-tags'))
      local file = torch.DiskFile(paths.concat(self.path,self.cacheFile..'-tags'), 'w')
      file:binary()
      file:writeObject(self.tags)
      file:close()
   end
end

function DataSetLabelMe:display(args)
   -- parse args:
   local title = args.title or 'DataSetLabelMe'
   local min = args.min
   local max = args.max
   local nbSamples = args.nbSamples or 50
   local scale = args.scale
   local resX = args.resX or 1200
   local resY = args.resY or 800

   -- compute some geometry params
   local painter = qtwidget.newwindow(resX,resY,title)
   local step_x = 0
   local step_y = 0
   local sizeX = self.maxX
   local sizeY = self.maxY
   if not scale then
      scale = math.sqrt(resX*resY/ (sizeX*sizeY*nbSamples))
      local nbx = math.floor(resX/(scale*sizeX))
      scale = resX/(sizeX*nbx)
   end

   -- load the samples and display them
   local dispTensor = torch.Tensor(3,sizeY*scale,sizeX*scale)
   local dispMask = torch.Tensor(sizeY*scale,sizeX*scale)
   local displayer = Displayer()
   for i=1,nbSamples do
      xlua.progress(i,nbSamples)
      self:loadSample(i)
      image.scale(self.currentSample, dispTensor, 'simple')
      image.scale(self.currentMask, dispMask, 'simple')
      local displayed = image.mergeSegmentation(dispTensor, dispMask, self.colorMap)
      if (step_x > (resX-sizeX*scale)) then
         step_x = 0
         step_y = step_y +  sizeY*scale
         if (step_y > (resY-sizeY*scale)) then
            break
         end
      end
      displayer:show{painter=painter,
                     tensor=displayed,
                     min=min, max=max,
                     offset_x=step_x,
                     offset_y=step_y}
      step_x = step_x +  sizeX*scale
   end
end
