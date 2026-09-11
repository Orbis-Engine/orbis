@@FN nullable instancetype Renderer::initWithWidth(
Renderer::Renderer(OrbisSurface *surface, OrbisBackend backend) {
  // Made by the host rather than here: where a frame goes is the one part of
  // presenting that differs by platform, and the host is what knows which.
  _surface = surface;
  _backendAsked = backend;
}

Renderer::~Renderer() {
  dispose();
  // A renderer that never started still owns the surface it was given.
  delete _surface;
  _surface = nullptr;
}

bool Renderer::initWithWidth(uint32_t width, uint32_t height) {
  // Before Filament, because starting Filament allocates through it. The
  // host made it; a renderer given none has nowhere to present.
  if (_surface == nullptr) return false;

  // Filament reports misuse by throwing, and an uncaught throw here would take
  // the whole application down rather than the one viewport that failed. The
  // message is worth keeping: it names the precondition, which is most of the
  // diagnosis.
  try {
    startWithWidth(width, height);
  } catch (const std::exception &error) {
    orbis::log("[orbis] Filament refused to start: %s", error.what());
    return false;
  } catch (...) {
    orbis::log("[orbis] Filament refused to start for an unknown reason.");
    return false;
  }
  return true;
}
@@FN Mesh *Renderer::meshAtPath(
Mesh *Renderer::meshAtPath(const std::string &path) {
  auto found = _meshes.find(path);
  if (found != _meshes.end()) {
    return found->second.asset ? &found->second : nullptr;
  }

  // Recorded either way, so a missing file is read from disk once rather than
  // on every frame of a drag.
  Mesh &entry = _meshes[path];

  const std::string &native = path;
  const double readFrom = orbis::now();
  std::vector<uint8_t> data;
  if (!orbis::readFile(native, data)) {
    orbis::log("[orbis] mesh unreadable: %s", native.c_str());
    _assetNotes[native] = "The file could not be read.";
    return nullptr;
  }

  const double parsedFrom = orbis::now();
  gltfio::FilamentInstance *first = nullptr;
  entry.asset = _assetLoader->createInstancedAsset(
      data.data(), static_cast<uint32_t>(data.size()), &first, 1);

  if (entry.asset == nullptr) {
    orbis::log("[orbis] mesh not glTF: %s (%lu bytes)", native.c_str(),
               (unsigned long)data.size());
    _assetNotes[native] = "This is not a glTF file that Filament can read.";
    return nullptr;
  }

  const double providedFrom = orbis::now();

  // The glTF's own path, so it can find the .bin and the textures sitting
  // beside it. A .glb carries everything and does not need it.
  //
  // The file, not the directory it is in. Filament takes the last component
  // off this to get the directory, so handing it a directory throws away the
  // real one: a scene at assets/bistro/Bistro.gltf looked for its textures in
  // assets/Textures, found none of the four hundred, and drew every surface
  // black. Nothing failed — loadResources still returned true — so the scene
  // rendered in the right shape with no colour in it, and in daylight at a
  // hundred thousand lux it was still black, which is what finally said this
  // was not a lighting problem.
  _resourceLoader->setConfiguration({
      .engine = _engine,
      .gltfPath = path.c_str(),
      .normalizeSkinningWeights = true,
  });

  // Begun rather than waited for.
  //
  // loadResources decodes every texture before it returns, and this scene has
  // four hundred of them — so the application stopped dead for several seconds
  // on a mesh that was, geometrically, ready almost at once. Filament will
  // decode them on its own threads instead, and the frame loop nudges it along
  // by calling asyncUpdateLoad until it says it is finished.
  //
  // What that buys is that the scene appears immediately. The geometry is
  // there on the next frame and the textures arrive over the following ones,
  // which is a scene assembling itself rather than an application that has
  // hung.
  // Which of the files it names are actually there.
  //
  // Worth doing before the load rather than trusting the result of it: the
  // loader reports success whether or not a texture opened. A scene of four
  // hundred images once failed every one of them — the base path was wrong by
  // a directory — and still returned true, so the geometry appeared with no
  // colour on it and nothing anywhere said why. Two hours of that is what
  // this loop is for.
  {
    const char *const *uris = entry.asset->getResourceUris();
    const size_t count = entry.asset->getResourceUriCount();
    std::vector<std::string> sample;
    size_t missing = 0;

    // Which files this model names, resolved to where they are.
    //
    // Worked out first and read second, because reading four hundred files
    // one after another spends nearly all of its time waiting: the disk can
    // serve many at once and a single-file-at-a-time loop asks it for one.
    const std::string beside = orbis::deletingLastPathComponent(native);
    std::vector<Wanted> wanted;
    wanted.reserve(count);
    for (size_t i = 0; i < count; i++) {
      if (uris[i] == nullptr) continue;
      const std::string uri(uris[i]);
      // Data URIs carry their own bytes and embedded resources have no URI at
      // all; only a file on disk can be missing.
      if (orbis::hasPrefix(uri, "data:")) continue;

      // A glTF URI is a URI, so a space in a file name arrives as %20. The
      // path has to be the decoded form or the file is looked for under a
      // name nothing on disk has — and the answer would be "missing", which
      // is the one kind of wrong that sounds authoritative.
      const std::string name = orbis::removingPercentEncoding(uri);
      wanted.push_back(
          {uris[i], orbis::appendingPathComponent(beside, name), nullptr, 0});
    }

    // Read them all at once. The reads touch nothing shared — each writes
    // only its own slot — so this needs no lock, and the files come back in
    // whatever order the disk finds convenient.
    if (!wanted.empty()) {
      // The body captures the pointer, not the vector: capturing the vector
      // copies it, and a copy is not where the bytes are wanted.
      Wanted *slots = wanted.data();
      orbis::parallelFor(wanted.size(),
                         [slots](size_t i) { readWholeFile(slots[i]); });
    }

    // Handed over one at a time, because Filament is not being called from
    // several threads at once and this is not where the time was.
    for (const Wanted &one : wanted) {
      if (one.bytes == nullptr) {
        missing++;
        // A few names, not four hundred. The count is the number that
        // matters and the names are only there to recognise them by.
        if (sample.size() < 3) {
          sample.push_back(orbis::lastPathComponent(one.path));
        }
        continue;
      }
      _resourceLoader->addResourceData(
          one.uri, filament::backend::BufferDescriptor(
                       one.bytes, one.size,
                       [](void *buffer, size_t, void *) { free(buffer); }));
    }

    if (missing > 0) {
      std::string names;
      for (size_t i = 0; i < sample.size(); i++) {
        names += (i == 0 ? "" : ", ") + sample[i];
      }
      _assetNotes[native] = orbis::format(
          "%lu of its %lu files are missing, starting with "
          "%s. It will draw untextured.",
          (unsigned long)missing, (unsigned long)count, names.c_str());
      orbis::log("[orbis] %s: %s", native.c_str(), _assetNotes[native].c_str());
    }
  }

  if (!_resourceLoader->asyncBeginLoad(entry.asset)) {
    orbis::log("[orbis] mesh resources failed: %s", native.c_str());
    _assetNotes[native] = "Its geometry or textures could not be loaded.";
  } else {
    _loadingResources = true;
    // What the load cost, in the three parts it is actually made of.
    //
    // "It takes a few seconds" is not a thing anybody can act on: reading the
    // file, parsing it, and decoding its textures are three different costs
    // with three different fixes, and until they are separated the only
    // available move is to guess. Printed rather than measured on request
    // because a load happens once and the number is wanted the first time,
    // not after somebody has reproduced it.
    _loadingName = native;
    _loadingResourceCount = entry.asset->getResourceUriCount();
    _loadingFrom = orbis::now();
    orbis::log("[orbis] %s: read %.0f ms, parsed %.0f ms, %zu files handed over "
               "in %.0f ms",
               orbis::lastPathComponent(native).c_str(),
               (parsedFrom - readFrom) * 1000,
               (providedFrom - parsedFrom) * 1000, _loadingResourceCount,
               (_loadingFrom - providedFrom) * 1000);
  }

  // Deliberately not calling releaseSourceData: more instances can only be
  // made while it is still there, and a second object using this mesh is the
  // ordinary case rather than the exception.
  entry.all.push_back(first);
  entry.spare.push_back(first);
  return &entry;
}
@@FN float Renderer::fieldStrength(
float Renderer::fieldStrength() {
  const float asked = _fieldParams[10];
  const float most = kFieldSafeGain / kFieldDamping;
  if (asked <= most) {
    _assetNotes.erase("fieldStrength");
    return asked;
  }
  _assetNotes["fieldStrength"] = orbis::format(
      "An irradiance field at a strength of %.1f feeds "
      "itself: it reads the picture it brightened, so the "
      "light goes round and drifts in hue rather than "
      "settling. Held at %.1f.",
      asked, most);
  return most;
}
@@FN Texture *Renderer::textureAtPath(
Texture *Renderer::textureAtPath(const std::string &path, bool srgb) {
  std::string identity = path + (srgb ? "|s" : "|l");

  // What a pass drew, rather than a file. Looked up every time rather than
  // cached: the target behind a name is rebuilt whenever the view is resized,
  // and a material still holding the old texture would be sampling something
  // the engine has destroyed.
  const std::string &wanted = path;
  if (wanted.rfind(kTargetScheme, 0) == 0) {
    return targetTextureNamed(wanted.substr(strlen(kTargetScheme)));
  }

  auto found = _ownTextures.find(identity);
  if (found != _ownTextures.end()) return found->second;

  // A failure is cached as null too. Forty objects naming a file that is not
  // there would otherwise each read the disk, every frame, forever.
  std::vector<uint8_t> data;
  Texture *texture = nullptr;
  if (orbis::readFile(path, data)) {
    const std::string extension = orbis::lowercasePathExtension(path);
    const char *mime = "image/png";
    gltfio::TextureProvider *provider = _ownStbTextures;
    if (extension == "jpg" || extension == "jpeg") {
      mime = "image/jpeg";
    } else if (extension == "ktx2") {
      mime = "image/ktx2";
      provider = _ownKtxTextures;
    }
    texture = provider->pushTexture(
        data.data(), data.size(), mime,
        srgb ? gltfio::TextureProvider::TextureFlags::sRGB
             : gltfio::TextureProvider::TextureFlags::NONE);
    if (texture != nullptr) {
      // The texture is usable now and its pixels arrive later, so an object
      // made of it appears white for a frame or two rather than not at all.
      _texturesPending++;
    }
  }
  _ownTextures[identity] = texture;
  return texture;
}
@@FN void Renderer::open(
void Renderer::open(Movie &movie, const std::string &path) {
  close(movie);
  movie.path = path;
  if (path.empty()) return;

  // The platform's decoder, or none where there is not one yet — which is
  // said rather than failed: a scene with a screen in it still draws, and
  // the screen is blank.
  movie.decoder = orbis::createVideoDecoder();
  if (movie.decoder == nullptr) {
    _videoNotes[path] =
        "Video is not supported on this platform yet, so this screen is "
        "blank.";
    return;
  }
  if (!movie.decoder->open(path)) {
    movie.decoder.reset();
    return;
  }

  // The external image is the decoder's own buffer, so the texture is a
  // handle rather than storage: no width, no height, no format, and nothing
  // uploaded when the picture changes.
  movie.texture = Texture::Builder()
                      .sampler(Texture::Sampler::SAMPLER_EXTERNAL)
                      .format(Texture::InternalFormat::RGBA8)
                      .build(*_engine);
}
@@DELETE void Renderer::restartIfLooping(
@@FN void Renderer::close(
void Renderer::close(Movie &movie) {
  // The decoder stops first — its end-of-file observer, its player, its
  // output — then the texture goes, and only then the last frame it showed,
  // which the decoder keeps until it is destroyed: releasing it while the
  // texture still pointed at it would pull the picture out from under a draw.
  if (movie.decoder != nullptr) movie.decoder->stop();
  if (movie.texture != nullptr) {
    _engine->destroy(movie.texture);
    movie.texture = nullptr;
  }
  movie.decoder.reset();
  movie.flags = -1;
  movie.seekToken = -1;
}
@@FN Texture *Renderer::cubemapAtPath(
Texture *Renderer::cubemapAtPath(const std::string &path, float3 *harmonics,
                                 bool *hasThose, const std::string &note) {
  *hasThose = false;

  std::vector<uint8_t> data;
  if (!orbis::readFile(path, data)) {
    _assetNotes[note] = orbis::format("%s could not be read.",
                                      orbis::lastPathComponent(path).c_str());
    return nullptr;
  }

  // The bundle owns the pixels and has to outlive the upload, so it is handed
  // to createTexture along with the callback that frees it once the driver has
  // taken a copy. Freeing it here would be a race with the render thread.
  auto *bundle = new image::Ktx1Bundle(data.data(),
                                       static_cast<uint32_t>(data.size()));

  if (!bundle->isCubemap()) {
    _assetNotes[note] = orbis::format(
        "%s is not a cubemap. cmgen writes one; a flat image will not do.",
        orbis::lastPathComponent(path).c_str());
    delete bundle;
    return nullptr;
  }

  *hasThose = bundle->getSphericalHarmonics(harmonics);

  Texture *texture = ktxreader::Ktx1Reader::createTexture(
      _engine, *bundle, false,
      [](void *userdata) {
        delete static_cast<image::Ktx1Bundle *>(userdata);
      },
      bundle);
  if (texture == nullptr) {
    _assetNotes[note] =
        orbis::format("%s is not a KTX this build can read.",
                      orbis::lastPathComponent(path).c_str());
    delete bundle;
  }
  return texture;
}
@@FN void Renderer::applyVideos(
void Renderer::applyVideos(const int64_t *keys, const int32_t *flags,
                           const float *params,
                           const std::vector<std::string> &paths,
                           uint32_t count) {
  if (_disposed) return;

  const uint64_t generation = ++_videoGeneration;
  _movieOrder.clear();
  _movieOrder.reserve(count);
  // Said again by this publish if it is still true, so a scene that stops
  // naming a video stops being told it cannot have it.
  _videoNotes.clear();

  for (uint32_t i = 0; i < count; i++) {
    Movie &movie = _movies[keys[i]];
    movie.seen = generation;
    const float *values = params + i * kVideoParams;
    const std::string path = i < paths.size() ? paths[i] : std::string();

    // A different file is a different video, whatever the key says. Anything
    // else — rate, volume, playing — is a change to this one.
    if (movie.decoder == nullptr || movie.path != path) open(movie, path);
    if (movie.decoder == nullptr) {
      _movieOrder.push_back(&movie);
      continue;
    }

    movie.looping = (flags[i] & 2) != 0;
    movie.decoder->setLooping(movie.looping);

    // The seek is reconciled by its token rather than by its target, so
    // saying the same seek sixty times a second is one seek and not sixty.
    const int32_t token = static_cast<int32_t>(values[3]);
    if (token != movie.seekToken) {
      movie.seekToken = token;
      if (values[2] >= 0) movie.decoder->seek(values[2]);
    }

    if (values[1] != movie.volume) {
      movie.volume = values[1];
      movie.decoder->setVolume(values[1]);
    }

    const bool playing = (flags[i] & 1) != 0;
    if (flags[i] != movie.flags || values[0] != movie.rate) {
      movie.flags = flags[i];
      movie.rate = values[0];
      if (playing) {
        movie.decoder->play(movie.rate);
      } else {
        movie.decoder->pause();
      }
    }

    _movieOrder.push_back(&movie);
  }

  for (auto it = _movies.begin(); it != _movies.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    close(it->second);
    it = _movies.erase(it);
  }
}
@@FN void Renderer::pumpVideos(
void Renderer::pumpVideos() {
  if (_movies.empty()) return;
  for (auto &entry : _movies) {
    Movie &movie = entry.second;
    if (movie.decoder == nullptr || movie.texture == nullptr) continue;
    // The decoder puts its newest frame on the texture where it lies, and
    // keeps it until the next one replaces it.
    movie.decoder->pump(*_engine, movie.texture);
  }
}
@@DELETE static std::vector<uint8_t> OrbisReadDecalPicture(
@@FN int32_t Renderer::decalLayerFor(
int32_t Renderer::decalLayerFor(const std::string &path, Notes &notes,
                                bool *uploaded) {
  const std::string &identity = path;
  auto found = _decalPictureLayer.find(identity);
  int32_t layer = found != _decalPictureLayer.end() ? found->second : -3;

  if (layer == -3) {
    if (_decalPictureCount >= kDecalPictureLayers) {
      layer = -2;
    } else {
      std::vector<uint8_t> pixels =
          orbis::readPicture(path, kDecalPictureSide);
      if (pixels.empty()) {
        layer = -1;
      } else {
        if (_decalPictures == nullptr) {
          _decalPictures =
              Texture::Builder()
                  .width(kDecalPictureSide)
                  .height(kDecalPictureSide)
                  .depth(kDecalPictureLayers)
                  .levels(kDecalPictureLevels)
                  .sampler(Texture::Sampler::SAMPLER_2D_ARRAY)
                  // sRGB, so the hardware decodes to linear before it
                  // filters. The pictures are premultiplied in sRGB, which is
                  // exact wherever they are opaque and slightly dark in a
                  // soft edge; drawing them into a linear 8-bit bitmap
                  // instead would band every dark picture.
                  .format(Texture::InternalFormat::SRGB8_A8)
                  .usage(Texture::Usage::SAMPLEABLE |
                         Texture::Usage::UPLOADABLE |
                         Texture::Usage::GEN_MIPMAPPABLE)
                  .build(*_engine);
          bindDecalsEverywhere();
        }
        layer = int32_t(_decalPictureCount++);
        const size_t bytes = pixels.size();
        uint8_t *copy = static_cast<uint8_t *>(malloc(bytes));
        memcpy(copy, pixels.data(), bytes);
        _decalPictures->setImage(
            *_engine, 0, 0, 0, uint32_t(layer), kDecalPictureSide,
            kDecalPictureSide, 1,
            Texture::PixelBufferDescriptor(
                copy, bytes, Texture::Format::RGBA, Texture::Type::UBYTE,
                [](void *buffer, size_t, void *) { free(buffer); }));
        *uploaded = true;
      }
    }
    _decalPictureLayer[identity] = layer;
  }

  if (layer == -1) {
    notes[path] = "This decal's picture could not be read. It is painted "
                  "as its tint alone.";
  } else if (layer == -2) {
    notes["decalPictures"] = orbis::format(
        "More than %u different decal pictures. The ones "
        "past it are painted as their tint alone.",
        kDecalPictureLayers);
  }
  return layer;
}
@@FN NSArray<NSNumber *> *Renderer::passTimings(
std::vector<PassTiming> Renderer::passTimings() {
  std::vector<PassTiming> out;
  out.reserve(_passes.size());
  for (const GraphPass &pass : _passes) {
    out.push_back({pass.milliseconds, pass.drawn});
  }
  return out;
}
@@FN nullable CVPixelBufferRef Renderer::copyPresentedBuffer(
void *Renderer::copyPresentedBuffer() {
  std::lock_guard<std::mutex> lock(_presentLock);
  // Opaque on the way out of the surface, and concrete only in the host that
  // asked for it: on Apple the plugin hands it straight to Flutter's texture
  // registry, and the registry wants a CVPixelBuffer.
  if (_surface == nullptr) return nullptr;
  return _surface->retainPresented(_presentedIndex);
}
@@FN NSDictionary<const std::string &, const std::string &> *Renderer::notes(
Notes Renderer::notes() {
  // What is wrong with *this* scene.
  //
  // A file that could not be read is remembered for as long as the renderer
  // lives, because it is only read once and re-reading it every frame to
  // find out it is still missing would be four hundred failed opens a
  // second. But remembering it is not the same as reporting it: a scene that
  // does not name that file has nothing wrong with it, and saying otherwise
  // put "the file could not be read" over a street that had loaded perfectly,
  // because a different example had failed a minute earlier.
  //
  // So the memory is kept and the answer is filtered to the files the scene
  // in front of us actually asks for.
  std::set<std::string> asked;
  for (const auto &pair : _drawn) {
    if (!pair.second.path.empty()) asked.insert(pair.second.path);
  }

  Notes all;
  for (const auto &entry : _assetNotes) {
    if (asked.count(entry.first) != 0) all[entry.first] = entry.second;
  }

  // These are already about the scene as it stands rather than about a
  // file, so they are reported as they are. Later ones win a shared key, as
  // addEntriesFromDictionary: had it.
  for (const auto &entry : _objectNotes) all[entry.first] = entry.second;
  for (const auto &entry : _lightNotes) all[entry.first] = entry.second;
  for (const auto &entry : _decalNotes) all[entry.first] = entry.second;
  for (const auto &entry : _splatNotes) all[entry.first] = entry.second;
  for (const auto &entry : _videoNotes) all[entry.first] = entry.second;
  return all;
}
@@DELETE void Renderer::dealloc(
@@APPEND
void Renderer::requestCapture() {
  std::lock_guard<std::mutex> lock(_captureLock);
  _captureWanted = true;
}

bool Renderer::capturedFrame(std::vector<uint8_t> &rgba, uint32_t &width,
                             uint32_t &height) {
  std::lock_guard<std::mutex> lock(_captureLock);
  if (!_captureReady) return false;
  rgba = _captured;
  width = _capturedWidth;
  height = _capturedHeight;
  return true;
}

void Renderer::readBackIfAsked() {
  {
    std::lock_guard<std::mutex> lock(_captureLock);
    if (!_captureWanted || _captureInFlight) return;
    _captureWanted = false;
    _captureInFlight = true;
  }

  // What arrives, and where it is going. Filament calls back with the
  // buffer and one pointer, so the size travels with the renderer.
  struct Arrival {
    Renderer *renderer;
    uint32_t width;
    uint32_t height;
    bool bottomFirst;
  };
  const size_t bytes = size_t(_width) * _height * 4;
  auto *pixels = static_cast<uint8_t *>(malloc(bytes));
  // Which way up the rows come. OpenGL reads a framebuffer bottom row first,
  // as glReadPixels always has. Metal hands back the texture's own rows, top
  // first — the headless host's first picture came out upside down until
  // this said so — and Vulkan's framebuffer has its origin at the top left
  // as Metal's does.
  auto *arrival = new Arrival{this, _width, _height,
                              _backend == ORBIS_BACKEND_OPENGL};
  _renderer->readPixels(
      0, 0, _width, _height,
      backend::PixelBufferDescriptor(
          pixels, bytes, backend::PixelDataFormat::RGBA,
          backend::PixelDataType::UBYTE,
          [](void *buffer, size_t, void *user) {
            auto *arrival = static_cast<Arrival *>(user);
            Renderer *self = arrival->renderer;
            const size_t stride = size_t(arrival->width) * 4;
            std::lock_guard<std::mutex> lock(self->_captureLock);
            self->_captured.resize(stride * arrival->height);
            // Stored top row first, which is how a picture is kept.
            const auto *source = static_cast<const uint8_t *>(buffer);
            for (uint32_t row = 0; row < arrival->height; row++) {
              const uint32_t from =
                  arrival->bottomFirst ? arrival->height - 1 - row : row;
              memcpy(self->_captured.data() + size_t(row) * stride,
                     source + size_t(from) * stride, stride);
            }
            self->_capturedWidth = arrival->width;
            self->_capturedHeight = arrival->height;
            self->_captureReady = true;
            self->_captureInFlight = false;
            free(buffer);
            delete arrival;
          },
          arrival));
}
