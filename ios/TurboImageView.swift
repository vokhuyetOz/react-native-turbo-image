import Nuke
import NukeUI
import SwiftSVG
import VisionKit
import Gifu
import React
import APNGKit

final class TurboImageView : UIView {
  
  private struct Constants {
    static let error = "error"
    static let state = "state"
    static let width = "width"
    static let height = "height"
    static let source = "source"
    static let svg = "svg"
    static let gif = "gif"
    static let apng = "apng"
  }
  
  private lazy var lazyImageView = LazyImageView()
  private var processors: [ImageProcessing] {
    return composeProcessors()
  }
  
  private var urlRequest: URLRequest?
  
  @objc var onStart: RCTDirectEventBlock?
  @objc var onFailure: RCTDirectEventBlock?
  @objc var onSuccess: RCTDirectEventBlock?
  @objc var onCompletion: RCTDirectEventBlock?
  
  @objc var source: NSDictionary? {
    didSet {
      guard let uri = source?.value(forKey: "uri") as? String,
            let url = URL(string: uri) else {
        onFailure?([
          Constants.error: "invalid source: \(String(describing: source))"
        ])
        return
      }
      urlRequest = URLRequest(url: url)
      if let headers = source?.value(forKey: "headers") as? [String:String] {
        urlRequest?.allHTTPHeaderFields = headers
      }
    }
  }
  
  @objc var rounded: Bool = false
  
  @objc var blur: NSNumber?
  
  @objc var monochrome: UIColor!
  
  @objc var resize: NSNumber?
  
  @objc var tint: UIColor!
    
  @objc var brightness: NSNumber?
    
  @objc var resizeMode = "contain" {
    didSet {
      let contentMode = ResizeMode(rawValue: resizeMode)?.contentMode
      lazyImageView.imageView.contentMode = contentMode ?? .scaleAspectFill
    }
  }
  
  @objc var indicator: NSDictionary? {
    didSet {
      guard let indicator else { return }
      let style = indicator.value(forKey: "style") as? String ?? "medium"
      let indicatorView = style == "large"
      ?  UIActivityIndicatorView(style: .large)
      : UIActivityIndicatorView(style: .medium)
      if let colorValue = indicator.value(forKey: "color") {
        indicatorView.color = RCTConvert.uiColor(colorValue)
      }
      lazyImageView.placeholderView = indicatorView
    }
  }
  
  @objc var placeholder: NSDictionary? {
    didSet {
      guard let placeholder else { return }
      
      if let blurhash = placeholder.value(forKey: "blurhash") as? String {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
          let image = UIImage(blurHash: blurhash)
          DispatchQueue.main.async { [self] in
            lazyImageView.placeholderImage = image
          }
        }
      }
      
      if let thumbhash = placeholder.value(forKey: "thumbhash") as? String {
        DispatchQueue.global(qos: .userInteractive).async {
          let image = UIImage(thumbhash: thumbhash)
          DispatchQueue.main.async { [self] in
            lazyImageView.placeholderImage = image
          }
        }
      }
    }
  }
  
  @objc var fadeDuration: NSNumber = 300
  
  @objc var cachePolicy = "memory" {
    didSet {
      let pipeline = CachePolicy(rawValue: cachePolicy)?.pipeline
      lazyImageView.pipeline = pipeline ?? .shared
    }
  }
  
  @objc var showPlaceholderOnFailure: Bool = false {
    didSet {
      if showPlaceholderOnFailure {
        lazyImageView.showPlaceholderOnFailure = showPlaceholderOnFailure
      }
    }
  }
  
  @objc var enableLiveTextInteraction: Bool = false
  
  @objc var format: NSString? {
    didSet {
      guard let format = format as? String else { return }
      if format == Constants.svg {
        handleSvg()
      }
      if format == Constants.gif {
        handleGif()
      }
      if format == Constants.apng {
        handleAPNG()
      }
    }
  }
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(lazyImageView)
    layer.masksToBounds = true
    lazyImageView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      lazyImageView.topAnchor.constraint(equalTo: topAnchor),
      lazyImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      lazyImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      lazyImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
  
  override func didSetProps(_ changedProps: [String]!) {
    super.didSetProps(changedProps)
    
    defer {
      if let urlRequest {
        lazyImageView.request = ImageRequest(urlRequest: urlRequest)
      }
    }
    
    if placeholder != nil {
      lazyImageView.transition = .none
    } else {
      lazyImageView.transition =
        .fadeIn(duration: (fadeDuration.doubleValue) / 1000)
    }
    
    registerObservers()
    lazyImageView.processors = processors
  }
  
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      lazyImageView.cancel()
    }
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - other formats
fileprivate extension TurboImageView {
  
  func handleSvg() {
    ImageDecoderRegistry.shared.register { context in
      context.urlResponse?.url?.absoluteString.hasSuffix(".svg") ?? false
      ? ImageDecoders.Empty()
      : nil
    }
    lazyImageView.makeImageView = { container in
      if let data = container.data {
        let view = UIView(SVGData: data)
        self.addSubview(view)
        return view
      }
      return nil
    }
  }
  
  func handleGif() {
    lazyImageView.makeImageView = { container in
      if container.type == .gif,
         let data = container.data {
        let view = GIFImageView()
        view.animate(withGIFData: data)
        return view
      }
      return nil
    }
  }
  
  func handleAPNG() {
    ImageDecoderRegistry.shared.register { context in
      // Signature bytes for the acTL chunk in an APNG file
      let acTLSignature = Data([0x61, 0x63, 0x54, 0x4C])
      // Search for the acTL chunk signature in the data
      if let _ = context.data.range(of: acTLSignature) {
        return ImageDecoders.Empty()
      } else {
        return nil
      }
    }
    
    lazyImageView.makeImageView = { container in
      guard let data = container.data else { return nil }
      let view = APNGImageView(frame: .zero)
      let image = try? APNGImage(data: data, decodingOptions: .cacheDecodedImages)
      view.image = image
      return view
    }
  }
  
}
// MARK: - processors
fileprivate extension TurboImageView {
  
  func composeProcessors() -> [ImageProcessing] {
    var initialProcessors: [ImageProcessing] = []
    
    if let resize {
      initialProcessors.append(
        ImageProcessors.Resize(width: resize.doubleValue))
    }
    
    if rounded {
      initialProcessors.append(
        ImageProcessors.Circle())
    }
    if let blur {
      initialProcessors.append(
        ImageProcessors.GaussianBlur(radius: blur.intValue))
    }
    if let monochrome {
      let name = "CIColorMonochrome"
      let parameters = [
        "inputIntensity": 1,
        "inputColor": CIColor(color: monochrome)
      ] as [String : Any]
      let identifier = "turboImage.monochrome"
      initialProcessors.append(
        ImageProcessors.CoreImageFilter(name: name,
                                        parameters: parameters,
                                        identifier: identifier))
    }
    if rounded {
      initialProcessors.append(
      ImageProcessors.Circle())
    }
    if let blur {
      initialProcessors.append(
        ImageProcessors.GaussianBlur(radius: blur.intValue))
    }
    if let monochrome {
      let name = "CIColorMonochrome"
      let parameters = [
        "inputIntensity": 1,
        "inputColor": CIColor(color: monochrome)
      ] as [String : Any]
      let identifier = "turboImage.monochrome"
      initialProcessors.append(
      ImageProcessors.CoreImageFilter(name: name,
                                        parameters: parameters,
                                        identifier: identifier))
    }
        
    if let tint {
      let tintProcessor = ImageProcessors
        .Anonymous(id: "turboImage.tint") { image in
          image.withTintColor(tint)
        }
      initialProcessors.append(tintProcessor)
    }
    if let brightness {
        let name = "CIColorCube"
        let size: UInt32 = 4
        let brightnessFactor: Float = Float(truncating: brightness)// Adjust brightness factor as desired
        let cubeDataSize = Int(size * size * size) * MemoryLayout<Float>.size * 4
        
        // Create a buffer for cube data
        var cubeData = [Float](repeating: 0, count: Int(cubeDataSize))
        // Populate cube data
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let index = Int(b * size * size + g * size + r) * 4
                    // Calculate R, G, B, A values (adjust brightness as needed)
                    
                    let rValue = (Float(r) / Float(size)) * brightnessFactor
                    let gValue = (Float(g) / Float(size)) * brightnessFactor
                    let bValue = (Float(b) / Float(size)) * brightnessFactor
                    let aValue: Float = 1
                    
                    cubeData[index + 0] = rValue
                    cubeData[index + 1] = gValue
                    cubeData[index + 2] = bValue
                    cubeData[index + 3] = aValue
                }
            }
        }
        
        // Create NSData from cube data
        let data = Data(bytes: &cubeData, count: cubeDataSize)
        let parameters = [
            "inputCubeDimension": size,
            "inputCubeData": data
        ] as [String : Any]
        
        let identifier = "turboImage.colorcube"
        
        let brightlessProcessor = ImageProcessors.CoreImageFilter(name: name, parameters: parameters, identifier: identifier)
        initialProcessors.append(brightlessProcessor)
    }
    
    return initialProcessors
  }
}

// MARK: - callback handler
fileprivate extension TurboImageView {
  
  func registerObservers() {
    lazyImageView.onStart = { task in
      self.onStartHandler(with: task)
    }
    
    lazyImageView.onSuccess = { response in
      self.onSuccessHandler(with: response)
    }
    
    lazyImageView.onFailure = { error in
      self.onFailureHandler(with: error)
    }
    
    lazyImageView.onCompletion = { result in
      self.onCompletionHandler(with: result)
      if self.enableLiveTextInteraction {
        self.handleLiveTextInteraction()
      }
    }
    
  }
  
  func onStartHandler(with task: ImageTask) {
    let payload = [
      Constants.state: "running"
    ]
    onStart?(payload)
  }
  
  func onSuccessHandler(with response: ImageResponse) {
    let payload = [
      Constants.width: response.image.size.width,
      Constants.height: response.image.size.height,
      Constants.state: response.request.url?.absoluteString ?? ""
    ] as [String : Any]
    
    onSuccess?(payload)
  }
  
  func onFailureHandler(with error: Error) {
    let payload = [
      Constants.error: error.localizedDescription,
    ]
    
    onFailure?(payload)
  }
  
  func onCompletionHandler(with result: Result<ImageResponse, any Error>) {
    onCompletion?([Constants.state: "completed"])
  }
  
}

extension TurboImageView {
  private func handleLiveTextInteraction() {
    guard #available(iOS 16.0, *), ImageAnalyzer.isSupported, let image = lazyImageView.imageView.image else { return }
    
    let interaction = ImageAnalysisInteraction()
    lazyImageView.imageView.addInteraction(interaction)
    Task {
      let analyzer = ImageAnalyzer()
      let configuration = ImageAnalyzer.Configuration([
        .text,.machineReadableCode,.visualLookUp
      ])
      let analysis = try? await analyzer.analyze(image, configuration: configuration)
      if let analysis {
        interaction.analysis = analysis
        interaction.preferredInteractionTypes = .automatic
      }
    }
  }
}

