import UIKit
import CoreML

/**
  View controller for the "Training Nearest Neighbors" screen.
 */
class TrainNearestNeighborsViewController: UITableViewController {
  @IBOutlet var trainButton: UIBarButtonItem!
  @IBOutlet var allButton: UIBarButtonItem!

  let headerNib = UINib(nibName: "SectionHeaderView", bundle: nil)

  var model: MLModel!
  var imagesByLabel: ImagesByLabel!
  var imageLoader: ImageLoader!
  var selected: Set<IndexPath> = []
  var alreadyTrained = Set<IndexPath>()

  override func viewDidLoad() {
    super.viewDidLoad()

    let cellNib = UINib(nibName: "ExampleCell", bundle: nil)
    tableView.register(cellNib, forCellReuseIdentifier: "ExampleCell")

    imageLoader = ImageLoader(dataset: imagesByLabel.dataset,
                              augment: false,
                              imageConstraint: imageConstraint(model: model))

    trainButton.isEnabled = false

    assert(model.modelDescription.isUpdatable)

    //print(model.modelDescription.trainingInputDescriptionsByName)
    //print(model.modelDescription.parameterDescriptionsByKey)
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    imagesByLabel.numberOfLabels
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    imagesByLabel.numberOfImages(for: imagesByLabel.labelName(of: section))
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    imagesByLabel.labelName(of: section)
  }

  override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    88
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let view = headerNib.instantiate(withOwner: self, options: nil)[0] as! SectionHeaderView
    view.label.text = imagesByLabel.labelName(of: section)
    view.libraryButton.isHidden = true
    view.cameraButton.isHidden = true
    return view
  }

  override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    132
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ExampleCell", for: indexPath) as! ExampleCell
    let label = imagesByLabel.labelName(of: indexPath.section)
    if let image = imagesByLabel.image(for: label, at: indexPath.row) {
      cell.exampleImageView.image = image
    } else {
      cell.exampleImageView.image = nil
      cell.selectedLabel.isHidden = true
    }
    updateSelectionMark(forCell: cell, at: indexPath)
    return cell
  }

  override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
    alreadyTrained.contains(indexPath) ? nil : indexPath
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if selected.contains(indexPath) {
      selected.remove(indexPath)
    } else {
      selected.insert(indexPath)
    }

    updateSelectionMark(at: indexPath)
    tableView.deselectRow(at: indexPath, animated: true)

    updateTrainButton()
  }

  private func updateSelectionMark(at indexPath: IndexPath) {
    if let cell = tableView.cellForRow(at: indexPath) as? ExampleCell {
      updateSelectionMark(forCell: cell, at: indexPath)
    }
  }

  private func updateSelectionMark(forCell cell: ExampleCell, at indexPath: IndexPath) {
    if alreadyTrained.contains(indexPath) {
      cell.selectedLabel.isHidden = false
      cell.selectedLabel.isEnabled = false
      cell.selectedLabel.text = "☆"
      cell.selectionStyle = .none
    } else {
      cell.selectedLabel.isHidden = !selected.contains(indexPath)
      cell.selectedLabel.isEnabled = true
      cell.selectedLabel.text = "★"
      cell.selectionStyle = .default
    }
  }

  @IBAction func allButtonPressed() {
    selected = []
    for section in 0..<tableView.numberOfSections {
      for row in 0..<tableView.numberOfRows(inSection: section) {
        let indexPath = IndexPath(row: row, section: section)
        if !alreadyTrained.contains(indexPath) {
          selected.insert(indexPath)
        }
      }
    }

    tableView.reloadData()
    updateTrainButton()
  }

  // MARK: - Training

  private func updateTrainButton() {
    trainButton.isEnabled = !selected.isEmpty
  }

  @IBAction func trainButtonPressed() {
    allButton.isEnabled = false
    trainButton.isEnabled = false
    view.isUserInteractionEnabled = false

    DispatchQueue.global().async {
      self.train()
    }
  }

  private func trainingDidComplete(success: Bool) {
    // Mark the examples as "already trained" and clear the selection.
    // Note that we don't remember this state after you leave this screen.
    alreadyTrained = alreadyTrained.union(selected)
    selected = []

    DispatchQueue.main.async {
      if success {
        self.showDialog(message: "Training finished!")
      } else {
        self.showDialog(message: "Errors during training")
      }

      self.tableView.reloadData()
      self.view.isUserInteractionEnabled = true
      self.allButton.isEnabled = true
    }
  }

  private func batchProvider() throws -> MLBatchProvider {
    var batchInputs: [MLFeatureProvider] = []

    for indexPath in selected {
      // For training we need to know the correct label of the example.
      let trueLabel = imagesByLabel.labelName(of: indexPath.section)

      // Load the image into a CVPixelBuffer.
      let index = imagesByLabel.flatIndex(for: trueLabel, at: indexPath.row)
      let featureValue = try imageLoader.featureValue(at: index)

      // Note: We could also have used an MLDictionaryFeatureProvider here,
      // as done in Predictor but this time with "image" and "label" fields.
      // We can also use the generated YourModelTrainingInput class, but note
      // that it expects a CVPixelBuffer for the image instead of an MLFeatureValue.

      if let pixelBuffer = featureValue.imageBufferValue {
        let featureProvider = FaceskNNTrainingInput(image: pixelBuffer, label: trueLabel)
        batchInputs.append(featureProvider)
      }
    }

    return MLArrayBatchProvider(array: batchInputs)
  }

  private func train() {
    do {
      let trainingData = try batchProvider()

      let updatableModelURL = Models.trainedNearestNeighborsURL

      let config = model.configuration

      let updateTask = try MLUpdateTask(forModelAt: updatableModelURL,
                                        trainingData: trainingData,
                                        configuration: config,
                                        completionHandler: { context in
        //print("Done!", context)

        // Overwrite the mlmodelc with the updated one.
        do {
          let tempURL = urlForModelInDocumentsDirectory("tempNearestNeighbors")
          try context.model.write(to: tempURL)

          Models.deleteTrainedNearestNeighbors()
          copyIfNotExists(from: tempURL, to: updatableModelURL)
          removeIfExists(at: tempURL)
        } catch {
          print("Error saving k-NN model:", error)
        }

        self.trainingDidComplete(success: true)
      })

      updateTask.resume()
    } catch {
      print("Error training k-NN:", error)
      trainingDidComplete(success: false)
    }
  }
}
