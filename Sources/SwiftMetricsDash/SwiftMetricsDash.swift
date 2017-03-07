/**
* Copyright IBM Corporation 2016
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
**/

import Kitura
import SwiftMetricsKitura
import SwiftMetricsBluemix
import SwiftMetrics
import SwiftyJSON
import KituraNet
import Foundation
import Configuration
import CloudFoundryConfig
import Dispatch

struct HTTPAggregateData: SMData {
  public var timeOfRequest: Int = 0
  public var url: String = ""
  public var longest: Double = 0
  public var average: Double = 0
  public var total: Int = 0
}

public class SwiftMetricsDash {

    var cpuDataStore:[JSON] = []
    var httpAggregateData: HTTPAggregateData = HTTPAggregateData()
    var httpURLData:[String:(totalTime:Double, numHits:Double)] = [:]
    var memDataStore:[JSON] = []
    var cpuData:[CPUData] = []
    let cpuQueue = DispatchQueue(label: "cpuStoreQueue")
    let httpQueue = DispatchQueue(label: "httpStoreQueue")
    let httpURLsQueue = DispatchQueue(label: "httpURLsQueue")
    let memQueue = DispatchQueue(label: "memStoreQueue")
    var monitor:SwiftMonitor
    var SM:SwiftMetrics

    public convenience init(swiftMetricsInstance : SwiftMetrics) throws {
       try self.init(swiftMetricsInstance : swiftMetricsInstance , endpoint: nil)
    }

    public init(swiftMetricsInstance : SwiftMetrics , endpoint: Router!) throws {
        // default to use passed in Router
        var create = false
        var router = Router()
        if endpoint == nil {
            create = true
        } else {
            router =  endpoint
        }
         self.SM = swiftMetricsInstance
        _ = SwiftMetricsKitura(swiftMetricsInstance: SM)
        self.monitor = SM.monitor()
        monitor.on(storeCPU)
        monitor.on(storeMem)
        monitor.on(storeHTTP)

        try startServer(createServer: create, router: router)
    }

    func startServer(createServer: Bool, router: Router) throws {
        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        var workingPath = ""
        if currentDir.contains(".build") {
            //we're below the Packages directory
            workingPath = currentDir
        } else {
         	//we're above the Packages directory
            workingPath = CommandLine.arguments[0]
        }
        let i = workingPath.range(of: ".build")
        var packagesPath = ""
        if i == nil {
            // we could be in bluemix
            packagesPath="/home/vcap/app/"
        } else {
            packagesPath = workingPath.substring(to: i!.lowerBound)
        }
        packagesPath.append("Packages/")
        let dirContents = try fm.contentsOfDirectory(atPath: packagesPath)
        for dir in dirContents {
            if dir.contains("SwiftMetrics") {
                packagesPath.append("\(dir)/public")
            }
        }
        router.all("/swiftmetrics-dash", middleware: StaticFileServer(path: packagesPath))
        router.get("/cpuRequest", handler: getcpuRequest)
        router.get("/memRequest", handler: getmemRequest)
        router.get("/envRequest", handler: getenvRequest)
        router.get("/cpuAverages", handler: getcpuAverages)
        router.get("/httpRequest", handler: gethttpRequest)
        router.get("/httpURLs", handler: gethttpURLs)
        if createServer {
            let configMgr = ConfigurationManager().load(.environmentVariables)
            Kitura.addHTTPServer(onPort: configMgr.port, with: router)
            print("SwiftMetricsDash : Starting on port \(configMgr.port)")
            Kitura.run()
        }
 	}

	func calculateAverageCPU() -> JSON {
		var cpuLine = JSON([])
		let tempArray = self.cpuData
		if (tempArray.count > 0) {
			var totalApplicationUse: Float = 0
			var totalSystemUse: Float = 0
			var time: Int = 0
			for cpuItem in tempArray {
				totalApplicationUse += cpuItem.percentUsedByApplication
				totalSystemUse += cpuItem.percentUsedBySystem
				time = cpuItem.timeOfSample
			}
			cpuLine = JSON([
				"time":"\(time)",
				"process":"\(totalApplicationUse/Float(tempArray.count))",
				"system":"\(totalSystemUse/Float(tempArray.count))"])
		}
		return cpuLine
	}


    func storeHTTP(myhttp: HTTPData) {
    	httpQueue.sync {
            if self.httpAggregateData.total == 0 {
                self.httpAggregateData.total = 1
                self.httpAggregateData.timeOfRequest = myhttp.timeOfRequest
                self.httpAggregateData.url = myhttp.url
                self.httpAggregateData.longest = myhttp.duration
                self.httpAggregateData.average = myhttp.duration
            } else {
              let oldTotalAsDouble:Double = Double(self.httpAggregateData.total)
              let newTotal = self.httpAggregateData.total + 1
              self.httpAggregateData.total = newTotal
              self.httpAggregateData.average = (self.httpAggregateData.average * oldTotalAsDouble + myhttp.duration) / Double(newTotal)
              if (myhttp.duration > self.httpAggregateData.longest) {
                self.httpAggregateData.longest = myhttp.duration
                self.httpAggregateData.url = myhttp.url
              }
            }
        }
        httpURLsQueue.sync {
            let urlTuple = self.httpURLData[myhttp.url]
            if(urlTuple != nil) {
                let averageResponseTime = urlTuple!.0
                let hits = urlTuple!.1
                // Recalculate the average
                self.httpURLData.updateValue(((averageResponseTime * hits + myhttp.duration)/(hits + 1), hits + 1), forKey: myhttp.url)
            } else {
                self.httpURLData.updateValue((myhttp.duration, 1), forKey: myhttp.url)
            }
        }
    }


    func storeCPU(cpu: CPUData) {
        let currentTime = NSDate().timeIntervalSince1970
        cpuQueue.sync {
            let tempArray = self.cpuDataStore
           	if tempArray.count > 0 {
           		for cpuJson in tempArray {
               		if(currentTime - (Double(cpuJson["time"].stringValue)! / 1000) > 1800) {
    	                self.cpuDataStore.removeFirst()
               		} else {
                    	break
    	            }
            	}
           	}
           	self.cpuData.append(cpu);
        	let cpuLine = JSON(["time":"\(cpu.timeOfSample)","process":"\(cpu.percentUsedByApplication)","system":"\(cpu.percentUsedBySystem)"])
        	self.cpuDataStore.append(cpuLine)
        }
    }

    func storeMem(mem: MemData) {
	    let currentTime = NSDate().timeIntervalSince1970
        memQueue.sync {
	        let tempArray = self.memDataStore
            if tempArray.count > 0 {
        	    for memJson in tempArray {
            	    if(currentTime - (Double(memJson["time"].stringValue)! / 1000) > 1800) {
	                    self.memDataStore.removeFirst()
            	    } else {
               		    break
	        	    }
	            }
	        }
   		    let memLine = JSON([
    	    	"time":"\(mem.timeOfSample)",
    		    "physical":"\(mem.applicationRAMUsed)",
	    	   "physical_used":"\(mem.totalRAMUsed)"
   		    ])
   		    self.memDataStore.append(memLine)
   	    }
    }

    public func getcpuRequest(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        response.headers["Content-Type"] = "application/json"
        let tempArray = self.cpuDataStore
        cpuQueue.sync {
            do {
               if tempArray.count > 0 {
                   try response.status(.OK).send(json: JSON(tempArray)).end()
                   self.cpuDataStore.removeAll()
               } else {
    		       try response.status(.OK).send(json: JSON([])).end()
               }
            } catch {
                print("SwiftMetricsDash ERROR : problem sending cpuRequest data")
            }
        }
    }

    public func getmemRequest(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
       	response.headers["Content-Type"] = "application/json"
        let tempArray = self.memDataStore
        memQueue.sync {
            do {
                if tempArray.count > 0 {
	    	        try response.status(.OK).send(json: JSON(tempArray)).end()
               	    self.memDataStore.removeAll()
                } else {
       			    try response.status(.OK).send(json: JSON([])).end()
                }
            } catch {
                print("SwiftMetricsDash ERROR : problem sending memRequest data")
            }
        }
    }

    public func getenvRequest(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
        response.headers["Content-Type"] = "application/json"
        var responseData: [JSON] = []
        for (param, value) in self.monitor.getEnvironmentData() {
            switch param {
                case "command.line":
                    let json: JSON = ["Parameter": "Command Line", "Value": value]
                    responseData.append(json)
                case "environment.HOSTNAME":
                    let json: JSON = ["Parameter": "Hostname", "Value": value]
                    responseData.append(json)
                case "os.arch":
                    let json: JSON = ["Parameter": "OS Architecture", "Value": value]
                    responseData.append(json)
                case "number.of.processors":
                    let json: JSON = ["Parameter": "Number of Processors", "Value": value]
                    responseData.append(json)
                default:
                    break
			}
        }
        do {
		    try response.status(.OK).send(json: JSON(responseData)).end()
        } catch {
            print("SwiftMetricsDash ERROR : problem sending environment data")
        }
    }

	public func getcpuAverages(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
        response.headers["Content-Type"] = "application/json"
        do {
		    try response.status(.OK).send(json: self.calculateAverageCPU()).end()
	    } catch {
	        print("SwiftMetricsDash ERROR : problem sending averageCPU data")
        }

    }

	public func gethttpRequest(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
        response.headers["Content-Type"] = "application/json"
        httpQueue.sync {
            do {
                if self.httpAggregateData.total > 0 {
                    let httpLine = JSON([
                        "time":"\(self.httpAggregateData.timeOfRequest)",
                        "url":"\(self.httpAggregateData.url)",
                        "longest":"\(self.httpAggregateData.longest)",
                        "average":"\(self.httpAggregateData.average)",
                        "total":"\(self.httpAggregateData.total)"])
                    try response.status(.OK).send(json:httpLine).end()
                    self.httpAggregateData = HTTPAggregateData()
                } else {
			        try response.status(.OK).send(json: JSON([])).end()
                }
            } catch {
                print("SwiftMetricsDash ERROR : problem sending httpRequest data")
            }

        }
    }

    public func gethttpURLs(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        httpURLsQueue.sync {
            response.headers["Content-Type"] = "application/json"
            var responseData:[JSON] = []
            for (key, value) in self.httpURLData {
                let json : JSON = ["url": key, "averageResponseTime": value.0]
                responseData.append(json)
            }
            do {
                try response.status(.OK).send(json: JSON(responseData)).end()
            } catch {
                print("SwiftMetricsDash ERROR : problem sending http URL data")
            }
        }
    }

}
