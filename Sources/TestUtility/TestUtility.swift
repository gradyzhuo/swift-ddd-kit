//
//  TestUtility.swift
//  
//
//  Created by Grady Zhuo on 2024/6/13.
//

import DDDCore
import KurrentDB
import Logging

let logger = Logger(label: "TestUtility")

extension KurrentDBClient {
    public func clearStreams<T: Projectable>(projectableType: T.Type, id: T.ID, execpted revision: KurrentDB.StreamRevision = .any, errorHandler: ((_ error: Error)->Void)? = nil) async {
        _ = try? await self.deleteStream(T.getStreamName(id: id)){ options in
            options.revision(expected: revision)
        }
    }
}

